"""用同一组测试窗口对比几个模型的判断。新模型出来时重跑一次，结果更新到 README。

    cd backend
    uv run --env-file .env python scripts/compare_models.py                  # 默认对比下面 MODELS
    uv run --env-file .env python scripts/compare_models.py qwen3.8-max ...  # 指定模型

每个模型每个用例真实调用一次 API（会产生少量费用）。
"""

import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.providers import ProviderError, QwenProvider  # noqa: E402
from app.schemas import JudgeRequest  # noqa: E402

MODELS = ["qwen-plus", "qwen3.8-flash", "qwen3.8-max"]

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

CASES = [("focused", FOCUSED), ("distracted", DISTRACTED), ("tense-but-still", TENSE_STILL)]
EXAMPLES = [{"label": "focused", "window": FOCUSED}, {"label": "distracted", "window": DISTRACTED}]


async def main(models: list[str]) -> None:
    print("| Model | Case | State | Score | Reason | Latency |")
    print("|---|---|---|---|---|---|")
    for model in models:
        p = QwenProvider(model)
        for name, window in CASES:
            t = time.perf_counter()
            try:
                j = await p.judge(JudgeRequest.model_validate({"window": window, "examples": EXAMPLES}))
                print(f"| {model} | {name} | {j.state} | {j.score} | {j.reason} | {time.perf_counter() - t:.1f}s |")
            except ProviderError as e:
                print(f"| {model} | {name} | ERROR | | {e} | |")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or MODELS))
