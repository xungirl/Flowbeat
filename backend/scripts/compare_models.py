"""用同一组测试窗口对比几个模型的判断，并测「锚定偏差」：模型是不是在照抄手表发来的规则分。

    cd backend
    uv run --env-file .env python scripts/compare_models.py --dry-run             # 只算要调用多少次，不花钱
    uv run --env-file .env python scripts/compare_models.py                       # 默认模型、3 种条件、2 轮
    uv run --env-file .env python scripts/compare_models.py --models qwen3.8-flash --runs 3
    uv run --env-file .env python scripts/compare_models.py --conditions rule     # 只复现旧行为
    uv run python scripts/compare_models.py --summarize scripts/results/<file>.json  # 重新打印汇总，不调 API

三种条件（同一个窗口，只改规则分）：
- none        不发 rule_score_mean（新默认）
- rule        发真实规则分（2026-11-11 的旧行为）
- misleading  发一个故意相反的规则分。分数跟着它跑 = 在抄规则分；不动 = 在独立看数据

每个 模型 × 用例 × 条件 × 轮次 真实调用一次 API（会产生少量费用），结果另存成 JSON。
"""

import argparse
import asyncio
import json
import statistics
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.providers import ProviderError, QwenProvider  # noqa: E402
from app.schemas import JudgeRequest  # noqa: E402

MODELS = ["qwen3.8-flash", "qwen3.8-max"]
CONDITIONS = ["none", "rule", "misleading"]

# --- 2026-11-11 的三个原始用例（数值不变，方便和 Run 1/2 对比） ---
FOCUSED = {
    "minute_of_session": 6, "local_time": "14:32", "baseline_hr": 68,
    "hr_mean": 70, "hr_min": 66, "hr_max": 74, "hr_trend": 1,
    "motion_mean": 0.012, "motion_max": 0.04, "still_ratio": 0.94,
    "away_seconds": 0, "rule_score_mean": 92,
}
DISTRACTED = {**FOCUSED, "hr_mean": 84, "hr_max": 91, "hr_trend": 9,
              "motion_mean": 0.13, "motion_max": 0.31, "still_ratio": 0.35, "rule_score_mean": 48}
# 难题：心率高但手腕很静——赶 deadline 式的「紧张但专注」，没有标准答案
TENSE_STILL = {**FOCUSED, "hr_mean": 88, "hr_max": 94, "hr_trend": 6, "still_ratio": 0.9, "rule_score_mean": 64}

# --- 2026-11-12 新增的三个模糊用例。rule_score_mean 按 FocusScorer 的公式（不含平滑）算：
#     100 - clamp((motion-0.02)/0.13)*60 - clamp((hr-base-5)/15)*40 ---
# 打字：手腕有小而规律的动作，心率在基线附近。规则会因为动作扣分，但这很可能是专注。
TYPING = {**FOCUSED, "minute_of_session": 14, "hr_mean": 71, "hr_min": 67, "hr_max": 76, "hr_trend": 2,
          "motion_mean": 0.045, "motion_max": 0.11, "still_ratio": 0.5, "rule_score_mean": 88}
# 刚走回座位：窗口里有 45 秒在走路，心率偏高但在下降。手表有 60 秒恢复期，不按心率扣分。
BACK_FROM_WALK = {**FOCUSED, "minute_of_session": 22, "hr_mean": 86, "hr_min": 78, "hr_max": 97, "hr_trend": -15,
                  "motion_mean": 0.06, "motion_max": 0.35, "still_ratio": 0.6, "away_seconds": 45,
                  "rule_score_mean": 82}
# 没有心率（表带松了）：只有动作数据，规则分因为没有心率扣分而偏高。
NO_HR = {"minute_of_session": 30, "local_time": "14:56", "baseline_hr": 68,
         "motion_mean": 0.025, "motion_max": 0.09, "still_ratio": 0.78, "away_seconds": 0,
         "rule_score_mean": 98}

CASES = [
    ("focused", FOCUSED), ("distracted", DISTRACTED), ("tense-but-still", TENSE_STILL),
    ("typing", TYPING), ("back-from-walk", BACK_FROM_WALK), ("no-hr", NO_HR),
]
EXAMPLES = [{"label": "focused", "window": FOCUSED}, {"label": "distracted", "window": DISTRACTED}]


def misleading_score(rule: float) -> float:
    """故意相反的规则分：真实分高就给很低，真实分低就给很高。"""
    return 15 if rule >= 50 else 90


def window_for(window: dict, condition: str) -> dict:
    if condition == "misleading":
        return {**window, "rule_score_mean": misleading_score(window["rule_score_mean"])}
    return window


async def run_all(models: list[str], conditions: list[str], runs: int) -> list[dict]:
    rows = []
    for model in models:
        p = QwenProvider(model)
        for run in range(1, runs + 1):
            for case, window in CASES:
                for cond in conditions:
                    w = window_for(window, cond)
                    req = JudgeRequest.model_validate({"window": w, "examples": EXAMPLES})
                    t = time.perf_counter()
                    row = {"model": model, "run": run, "case": case, "condition": cond,
                           "rule_sent": None if cond == "none" else w["rule_score_mean"],
                           "rule_true": window["rule_score_mean"]}
                    try:
                        j = await p.judge(req, include_rule_score=(cond != "none"))
                        row.update(state=j.state, score=j.score, reason=j.reason,
                                   latency_s=round(time.perf_counter() - t, 2),
                                   tokens_in=p.last_usage[0] if p.last_usage else None,
                                   tokens_out=p.last_usage[1] if p.last_usage else None)
                    except ProviderError as e:
                        row.update(state="ERROR", score=None, reason=str(e),
                                   latency_s=round(time.perf_counter() - t, 2))
                    rows.append(row)
                    print(f"{model:15} r{run} {case:16} {cond:10} -> {row['state']:10} {row['score']!s:>4} "
                          f"{row['latency_s']}s  {row['reason']}", flush=True)
    return rows


def _find(rows, model, case, cond, run):
    return next((r for r in rows if (r["model"], r["case"], r["condition"], r["run"]) == (model, case, cond, run)), None)


def summarize(rows: list[dict]) -> str:
    """把原始结果压成 README 用的几张表。"""
    ok = [r for r in rows if r["state"] != "ERROR"]
    out = []
    models = list(dict.fromkeys(r["model"] for r in rows))
    conds = [c for c in CONDITIONS if any(r["condition"] == c for r in rows)]
    cases = list(dict.fromkeys(r["case"] for r in rows))

    out.append("Anchoring: does the LLM score follow the rule score?\n")
    out.append("| Model | Condition | score == rule score in this window | score == true rule score | "
               "mean abs(score − true rule score) | cells with same verdict every run |")
    out.append("|---|---|---|---|---|---|")
    for m in models:
        for c in conds:
            rs = [r for r in ok if r["model"] == m and r["condition"] == c]
            if not rs:
                continue
            eq = "n/a (not sent)" if c == "none" else f"{sum(r['score'] == round(r['rule_sent']) for r in rs)}/{len(rs)}"
            eq_true = f"{sum(r['score'] == round(r['rule_true']) for r in rs)}/{len(rs)}"
            mad = statistics.mean(abs(r["score"] - r["rule_true"]) for r in rs)
            all_rs = [r for r in rows if r["model"] == m and r["condition"] == c]
            stable = sum(len({r["state"] for r in all_rs if r["case"] == case}) == 1 for case in cases)
            out.append(f"| {m} | {c} | {eq} | {eq_true} | {mad:.1f} | {stable}/{len(cases)} |")

    if {"rule", "misleading"} <= set(conds):
        out.append("\nSensitivity: same window, true rule score swapped for a misleading one. "
                   "Slope 1.0 = the score moves point-for-point with the rule score, 0 = ignores it.\n")
        out.append("| Model | Mean slope (Δscore / Δrule score) | Verdict changed (rule → misleading) |")
        out.append("|---|---|---|")
        for m in models:
            slopes, flips, pairs = [], 0, 0
            for case in cases:
                for run in sorted({r["run"] for r in ok if r["model"] == m}):
                    a, b = _find(ok, m, case, "rule", run), _find(ok, m, case, "misleading", run)
                    if not a or not b:
                        continue
                    pairs += 1
                    flips += a["state"] != b["state"]
                    slopes.append((b["score"] - a["score"]) / (b["rule_sent"] - a["rule_sent"]))
            if slopes:
                out.append(f"| {m} | {statistics.mean(slopes):.2f} | {flips}/{pairs} |")

    out.append("\nPer case (state per run · score per run):\n")
    out.append("| Model | Case | " + " | ".join(conds) + " |")
    out.append("|---|---|" + "---|" * len(conds))
    for m in models:
        for case in cases:
            cells = []
            for c in conds:
                rs = sorted((r for r in rows if r["model"] == m and r["case"] == case and r["condition"] == c),
                            key=lambda r: r["run"])
                cells.append("/".join(r["state"] for r in rs) + " · " + "/".join(str(r["score"]) for r in rs))
            out.append(f"| {m} | {case} | " + " | ".join(cells) + " |")

    out.append("\nStability and latency:\n")
    out.append("| Model | Cells with the same verdict in every run | Latency median (min–max) | Tokens in / out (median) | Errors |")
    out.append("|---|---|---|---|---|")
    for m in models:
        rs = [r for r in rows if r["model"] == m]
        cells = {(r["case"], r["condition"]) for r in rs}
        stable = sum(len({r["state"] for r in rs if (r["case"], r["condition"]) == cell}) == 1 for cell in cells)
        lat = [r["latency_s"] for r in rs if r["state"] != "ERROR"]
        tin = [r["tokens_in"] for r in rs if r.get("tokens_in")]
        tout = [r["tokens_out"] for r in rs if r.get("tokens_out")]
        errors = sum(r["state"] == "ERROR" for r in rs)
        lat_s = f"{statistics.median(lat):.2f} s ({min(lat):.2f}–{max(lat):.2f})" if lat else "n/a"
        tok_s = f"{statistics.median(tin):.0f} / {statistics.median(tout):.0f}" if tin else "n/a"
        out.append(f"| {m} | {stable}/{len(cells)} | {lat_s} | {tok_s} | {errors} |")
    return "\n".join(out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", nargs="+", default=MODELS)
    ap.add_argument("--conditions", nargs="+", default=CONDITIONS, choices=CONDITIONS)
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--out", type=Path, help="results JSON (default: scripts/results/compare-<date>-<model>.json)")
    ap.add_argument("--dry-run", action="store_true", help="print the number of API calls and exit")
    ap.add_argument("--summarize", nargs="+", type=Path, help="re-print the summary of saved results (no API calls)")
    args = ap.parse_args()

    if args.summarize:
        rows = [r for f in args.summarize for r in json.loads(f.read_text())["rows"]]
        print(summarize(rows))
        return
    n = len(args.models) * len(CASES) * len(args.conditions) * args.runs
    print(f"{len(args.models)} models × {len(CASES)} cases × {len(args.conditions)} conditions × {args.runs} runs = {n} API calls")
    if args.dry_run:
        return
    rows = asyncio.run(run_all(args.models, args.conditions, args.runs))
    out = args.out or Path(__file__).parent / "results" / f"compare-{date.today()}-{'-'.join(args.models)}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"date": str(date.today()), "runs": args.runs, "conditions": args.conditions,
                               "examples": EXAMPLES, "cases": dict(CASES), "rows": rows},
                              ensure_ascii=False, indent=1))
    print(f"\nsaved {len(rows)} rows to {out}\n")
    print(summarize(rows))


if __name__ == "__main__":
    main()
