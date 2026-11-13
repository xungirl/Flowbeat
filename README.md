# Flowbeat · 心流

**Flowbeat** is an Apple Watch app that estimates whether you're in a state of focus ("flow") from your **heart rate** and **wrist motion**, and shows it as a live 0–100 focus score.

> Flowbeat 是一款 Apple Watch app：通过**心率**和**手腕动作**判断你是否进入了「心流」专注状态，实时给出 0–100 的专注指数。

## Architecture

```
 Apple Watch                                     Mac / cloud                     LLM
┌─────────────────────────────────┐            ┌──────────────────────┐      ┌──────────────────┐
│ HealthKit heart rate (~5 s)     │            │ FastAPI  :8765       │      │ Qwen qwen3.8-flash│
│ CoreMotion wrist accel (25 Hz)  │            │                      │      │  (DashScope, CN)  │
│ Activity: walking → "away"      │            │ /v1/judge  ──────────┼─────▶│        or         │
│        │                        │  every     │  window + your labels│      │ Claude Haiku 5.5  │
│        ▼ every 1 s              │  2 min     │  as few-shot examples│◀─────┤                   │
│ FocusScorer (rules) → ring 0–100│──summary──▶│                      │      └──────────────────┘
│        │                        │◀─judgment──│ /v1/review (on stop) │
│        ▼                        │  {state,   │                      │
│ AI pill · summary · JSON log    │  score,    │ .env: API keys       │
│ 专注/走神 labels → LabelStore   │  reason}   │ (never on the watch) │
└─────────────────────────────────┘            └──────────────────────┘
```

- **Per second, on the watch, offline**: rule-based score in the ring. Works without network.
- **Every 2 minutes, via backend**: a statistics-only summary (no raw samples) goes to the LLM together with your own labeled examples; the reason string is shown under the ring.
- **On stop**: an AI review card on the summary page. Everything is saved to `Documents/sessions/*.json` (samples + windows + judgments + review).

## How it works

| File | Role |
|---|---|
| `Flowbeat/FocusSession.swift` | Starts an `HKWorkoutSession` (mind & body) to get heart rate every few seconds and keep running in the background; reads wrist acceleration via CoreMotion at 25 Hz; scores once per second. The workout is discarded at the end, so nothing is written to Health. |
| `Flowbeat/FocusScorer.swift` | Pure scoring logic: a 60 s calibration sets your resting-HR baseline → motion penalty (≤ 60) + elevated-HR penalty (≤ 40) → exponential smoothing. |
| `Flowbeat/ContentView.swift` | Start / in-session / summary screens. |

During a session you can tap **专注 (focused)** or **走神 (distracted)** to label the moment. Each session is saved as JSON in the app's `Documents/sessions/`, to be used later to tune the scoring or train a personal model.

Blood oxygen is intentionally not used: third-party apps can't trigger SpO₂ readings, and it doesn't change with focus.

## AI judge (backend + LLM)

Every 2 minutes the watch sends a compact **window summary** (HR mean/trend vs. baseline, wrist stillness, away time, rule score) to a small FastAPI backend, which asks an LLM — **Qwen (qwen3.8-flash)** or **Claude Haiku 5.5**, switchable with `LLM_PROVIDER` — for `{state, score, reason}`. Your own **focused/distracted labels** (last 20, stored on the watch) are sent along as few-shot examples, so the model judges against *your* body rather than generic thresholds — useful when there isn't enough data to train a model yet. At the end of a session the backend returns a short AI review and one tip.

The per-second score stays rule-based and on-device; the LLM adds a periodic second opinion and works offline-tolerant (the watch keeps working if the backend is unreachable).

```bash
cd backend
uv sync
cp .env.example .env                     # then put your key in .env (git-ignored)
uv run uvicorn app.main:app --env-file .env --host 0.0.0.0 --port 8765
uv run pytest                            # tests use the fake provider
```

Optional env: `CLAUDE_MODEL` (default `claude-haiku-5-5`), `LLM_PROVIDER=claude|qwen|fake`, `QWEN_MODEL` (default `qwen3.8-flash`), `FLOWBEAT_TOKEN` (shared secret; set the same value in `AIConfig.token`). The simulator talks to `localhost:8765`; for a real watch set `AIConfig.baseURL` in `Flowbeat/AIJudge.swift` to your Mac's `.local` name on the same Wi-Fi.

## Model comparison

### Run 3 — 2026-11-12: is the anchoring gone?

After Run 2 showed every score equal to the `rule_score_mean` we sent, the judge prompt stopped sending it (commit `39d170c`; `JUDGE_INCLUDE_RULE_SCORE=1` brings it back). This run measures what that changed. It uses `backend/scripts/compare_models.py`, whose raw rows are in `backend/scripts/results/compare-2026-11-12-*.json`.

**Setup.** There are 6 windows: the 3 from Runs 1–2, plus 3 new ambiguous ones.
- `typing`: small, regular wrist motion with HR at baseline.
- `back-from-walk`: 45 s of walking in the window, with HR high but falling.
- `no-hr`: motion only, no heart-rate data.

The few-shot examples are the same 2 as before. Each window is judged under 3 conditions:
- `none`: no rule score in the prompt (the new default).
- `rule`: the true rule score, which was the old behavior.
- `misleading`: the window's rule score is replaced by an opposite one (15 if the true score is ≥ 50, else 90).

`qwen3.8-flash` ran 3 times and `qwen3.8-max` ran 2 times, for **90 real API calls** with 0 errors.

| Model | Condition | score == rule score in window | score == true rule score | mean abs(score − true rule score) | cells with same verdict every run |
|---|---|---|---|---|---|
| `qwen3.8-flash` | none | n/a (not sent) | **0/18** | 28.2 | 5/6 |
| `qwen3.8-flash` | rule | 6/18 | 6/18 | 11.4 | 5/6 |
| `qwen3.8-flash` | misleading | 0/18 | 2/18 | 24.4 | 6/6 |
| `qwen3.8-max` | none | n/a (not sent) | **0/12** | 24.2 | 5/6 |
| `qwen3.8-max` | rule | 4/12 | 4/12 | 10.4 | 6/6 |
| `qwen3.8-max` | misleading | 0/12 | 3/12 | 29.3 | 6/6 |

| Model | Δscore / Δrule score when the rule score is swapped for a misleading one | Verdict changed (rule → misleading) | Latency median (min–max) | Tokens in / out (median) |
|---|---|---|---|---|
| `qwen3.8-flash` | 0.05 | 4/18 | 1.10 s (0.78–2.06) | 749 / 35 |
| `qwen3.8-max` | 0.24 | 6/12 | 1.51 s (1.23–2.69) | 749 / 24 |

Verdicts per run (`none` = new default · `rule` = old behavior):

| Case | flash `none` | flash `rule` | max `none` | max `rule` |
|---|---|---|---|---|
| focused | focused ×3 · 95/95/95 | focused ×3 · 92/92/92 | focused ×2 · 95/95 | focused ×2 · 92/92 |
| distracted | distracted ×3 · 20/20/10 | distracted ×3 · 48/48/48 | distracted ×2 · 15/15 | distracted ×2 · 48/48 |
| tense-but-still | focused, focused, **distracted** · 85/85/30 | focused, **distracted**, focused · 75/45/85 | focused, **unclear** · 72/40 | unclear ×2 · 50/50 |
| typing | distracted ×3 · 40/40/45 | focused ×3 · 85/85/85 | focused ×2 · 72/68 | focused ×2 · 82/82 |
| back-from-walk | distracted ×3 · 30/30/35 | distracted ×3 · 40/35/35 | distracted ×2 · 25/25 | unclear · 50/45 |
| no-hr | focused ×3 · 85/85/85 | focused ×3 · 95/95/95 | focused ×2 · 78/82 | focused ×2 · 90/90 |

What this shows:
- **The exact copying is gone.** With the rule score removed, 0 of 30 scores equal the rule score. Before, the 92 / 48 copies came back (10 of 30 under `rule`).
- **The copies came from the few-shot examples, not from the current window.** Under `misleading`, the window said 15, but the `focused` case still scored 92 in 2/3 (flash) and 2/2 (max) runs. 92 is the rule score stored inside the matching labeled example. That's why the fix strips `rule_score_mean` from the examples too, not only from the window.
- **The rule score still steered verdicts on ambiguous windows.** Swapping it changed the verdict in 4/18 (flash) and 6/12 (max) pairs. For example, flash called `typing` focused with the true rule score but distracted with the misleading one or with none. So it wasn't inert, and removing it makes the LLM an actual second opinion.
- **Independent isn't the same as correct.** Without the rule score, the two models disagree on `typing` (flash: distracted 3/3, max: focused 2/2). Both models are unstable on `tense-but-still` (1 flip each). There is no ground truth for these windows. Only labeled sessions from a real watch can say which judgment is right.
- `qwen3.8-flash` stays the default: it's ~0.4 s faster at the median, and its scores move least with the rule score (slope 0.05 vs 0.24).
- Caveats: this is 6 synthetic windows and 2–3 runs per cell, a smoke test rather than a statistical evaluation. The scores aren't validated against anything.

### Runs 1–2 — 2026-11-11

Same three windows, same two few-shot examples (one labeled focused, one distracted), one call per cell. The third case is deliberately ambiguous: high heart rate but a still wrist, like being tense but locked in before a deadline. It has no single right answer.

**Run 2 — 2026-11-11** (`backend/scripts/compare_models.py`)

| Model | Focused case | Distracted case | Tense-but-still case | Latency |
|---|---|---|---|---|
| `qwen-plus` (alias of an older snapshot) | focused 92 · 手腕静止 2 分钟，心率平稳 | distracted 48 · 心率波动大，手腕动作零碎 | **distracted 30** · 心率明显升高但手腕静止 | 1.1–2.5 s |
| **`qwen3.8-flash`** (newest gen, chosen) | focused 92 · 数据与用户专注标注完全一致 | distracted 48 · 心率波动大，手腕动作零碎 | focused 85 · 手腕静止，心率虽高但符合专注特征 | **0.7–1.4 s** |
| `qwen3.8-max` (newest gen, flagship) | focused 92 · 手腕静止2分钟，心率平稳 | distracted 48 · 心率偏高且手腕动作零碎，与走神标注一致 | unclear 50 · 手腕静止但心率偏高，状态矛盾 | 1.5–2.2 s |

**Run 1 — 2026-11-11, same inputs:** identical verdicts on the two clear cases. On the ambiguous case `qwen-plus` said **focused 85**, `qwen3.8-flash` focused 85, `qwen3.8-max` unclear 50.

Findings:
- All three models agree on clear cases, so the main differences are latency and how they handle ambiguous data.
- `qwen-plus` **flipped** on the ambiguous case between runs (focused 85 → distracted 30); the newer models gave the same answer both times.
- `qwen3.8-max` is the most conservative: it follows the prompt's "contradictory data → unclear" rule. `qwen3.8-flash` leans on the prompt's note that tension ≠ distraction.
- **Known issue (fixed in Run 3):** every model's score equals the `rule_score_mean` we send (92 / 48), so the LLM is anchoring on the on-device rule score instead of judging independently.
- Token use per judgment: ~520–760 input / ~20–40 output (grows by ~110 input tokens per stored label, up to 20).

Re-run when new models ship:

```bash
cd backend
uv run python scripts/compare_models.py --dry-run                              # prints the number of API calls
uv run --env-file .env python scripts/compare_models.py                       # flash + max, 3 conditions, 2 runs
uv run --env-file .env python scripts/compare_models.py --models qwen3.8-flash --runs 3
uv run python scripts/compare_models.py --summarize scripts/results/*.json    # re-print tables, no API calls
```

## Run it

```bash
brew install xcodegen
xcodegen generate        # generates Flowbeat.xcodeproj from project.yml (not committed)
open Flowbeat.xcodeproj
```

1. Target `Flowbeat` → **Signing & Capabilities** → pick your Team (a free Apple ID works for personal devices).
2. Turn on **Developer Mode** on both iPhone and Apple Watch.
3. Choose your Apple Watch as the run destination → ⌘R.

The simulator is fine for UI, but it has no real sensors — use a real watch to see meaningful scores.

## Project Journey

Everything below happened on 2026-11-11 (see `git log`). Each stage links to the section above that holds the details, so they aren't repeated here.

### 1. v0: rule-based focus score on the watch (`13a8f6a`)
- **Goal:** a live 0–100 focus estimate from signals a watch can read continuously.
- **Decision:** heart rate (HealthKit) + wrist acceleration (CoreMotion, 25 Hz), scored once per second on-device with transparent rules instead of a model, because there was no labeled data yet. SpO₂ was rejected because third-party apps can't trigger readings, and it doesn't track focus (see [How it works](#how-it-works)).
- **Built:** `FocusScorer.swift`: a 60 s calibration takes the median HR as your baseline, then a motion penalty (≤ 60) and an elevated-HR penalty (≤ 40), with exponential smoothing. An `HKWorkoutSession` keeps HR flowing in the background and is discarded at the end, so nothing is written to Health. 专注/走神 labels and full sessions are saved as JSON for later tuning.

### 2. Problem: HealthKit permission failed silently (`8a2349b`)
- **Surprise:** if the user dismisses or denies the HealthKit prompt, `requestAuthorization` does **not** throw, so a workout could start without data.
- **Fix:** request authorization as soon as the app opens, then re-check `authorizationStatus` before starting a session and show a clear message if it's missing.

### 3. Away detection (`7f8fb90`)
- **Problem:** walking away from the desk was scored as "distracted", and HR stays high for a while after sitting back down.
- **Built:** `CMMotionActivityManager` walking/running marks time as **away**. Away time isn't scored, doesn't count against the focus ratio and is excluded from the calibration baseline. There's a 60 s HR-penalty grace period after sitting back down, and the summary shows away count/duration and steps (CMPedometer).
- **Verified:** in the simulator via a simulated-sensor demo cycle (focus 35 s → distracted 10 s → walking 15 s, `0b91e25`).

### 4. UI redesign and icon (`8969b69`, `a704602`)
- Gradient score ring with state colors, controls on a second vertical page, haptic + toast on labeling. The icon is generated in code (`tools/make_icon.swift`).

### 5. LLM second opinion via a backend (`c923221`, `df908d3`, `eac7655`)
- **Goal:** personalize judgments without enough data to train a model.
- **Decision:** keep the per-second score rule-based and offline. Every 2 minutes, send a **statistics-only window summary** (no raw samples) to a FastAPI backend, along with your last 20 labeled moments as **few-shot examples**. The LLM returns `{state, score, reason}`, plus `/v1/review` at the end of a session. API keys live in a git-ignored `.env` on the backend, never on the watch. If the backend is down, the watch shows a hint and local scoring continues.
- **Built:** a Claude provider (structured output via Pydantic) and a `FakeProvider` that is selected automatically when no key is set. There's an optional shared-secret header.
- **Verified:** `backend/tests` has 6 pytest tests on the fake provider (`uv run pytest`).
- **Note:** the Claude Haiku provider is implemented but the comparison and live runs below were done with Qwen.

### 6. Switch to Qwen, then pick a model by measurement (`4559ae3`, `579afed`, `783fb49`)
- **Built:** `QwenProvider` via DashScope's OpenAI-compatible API, using JSON mode + Pydantic validation, with `enable_thinking=False` for speed and cost on a simple classification. `LLM_PROVIDER=claude|qwen|fake` picks the provider.
- **Compared:** `qwen-plus` vs `qwen3.8-flash` vs `qwen3.8-max` on 3 fixed windows (focused, distracted, deliberately ambiguous "tense but still"), with 2 runs. Full table, findings and re-run command are in [Model comparison](#model-comparison); the script is `backend/scripts/compare_models.py`.
- **Decision:** `qwen3.8-flash` became the default. It gave the same verdicts both runs at the lowest latency (0.7–1.4 s). `qwen-plus` flipped on the ambiguous case between runs, and `qwen3.8-max` was slower and called it "unclear".
- **Surprise (open issue):** on the clear cases every model's score equaled the `rule_score_mean` sent in the request (92 / 48). The LLM is anchoring on the on-device rule score rather than judging independently.
- **Measured:** ~1–2 s per judge call live, ~520–760 input / ~20–40 output tokens. Input grows by ~110 tokens per stored label.

### Key metrics

| Metric | Value | How measured | Source |
|---|---|---|---|
| Scoring cadence | 1 score/s on-device, 25 Hz motion | timer + `deviceMotionUpdateInterval` | `Flowbeat/FocusSession.swift` |
| Calibration | 60 s, median resting HR | `calibrationSeconds` | `Flowbeat/FocusScorer.swift` |
| LLM judge interval | every 120 s (30 s in simulator) | `AIConfig.judgeInterval` | `Flowbeat/AIJudge.swift` |
| Models compared | 3 Qwen models × 3 cases × 2 runs, 1 call per cell | `compare_models.py` | [Model comparison](#model-comparison) |
| Chosen model latency | 0.7–1.4 s (`qwen3.8-flash`) | wall clock per call in the script | [Model comparison](#model-comparison) |
| Tokens per judgment | ~520–760 in / ~20–40 out | API usage on live calls | [Model comparison](#model-comparison) |
| Backend tests | 6 passing | `uv run pytest` (fake provider) | `backend/tests/` |

Caveat: the comparison is a small smoke test (one call per cell, two runs), not a statistical evaluation, and all results so far are from the simulator with simulated sensors.

### Next steps
- Run on a real Apple Watch (only the simulator has been used so far) and collect labeled sessions.
- Fix the anchoring issue: drop `rule_score_mean` from the request and re-run the comparison.
- Then follow the [Roadmap](#roadmap): iPhone companion, threshold tuning or a personal model, and a Cloud Run backend.

## Roadmap

- [x] v0: live score on the watch, calibration, labeling, JSON logging
- [x] Away detection: walking/running (CMMotionActivityManager) pauses scoring and is not counted as distraction; 60 s heart-rate recovery grace after sitting back down; step count
- [ ] iPhone companion: sync sessions (WatchConnectivity) and chart your focus timeline
- [ ] Tune thresholds / train a personal model (Create ML) from labeled sessions
- [ ] Use system HRV (SDNN) as an extra signal
- [x] LLM judge every 2 min with few-shot personalization + end-of-session AI review (Claude Haiku 5.5)
- [x] Qwen (通义千问, qwen3.8-flash via DashScope OpenAI-compatible API) provider — current default
- [ ] Deploy backend to Cloud Run (HTTPS)
- [ ] Integrate with [Nod](https://github.com/xungirl/Nod): hold notifications while you're in flow

> Flowbeat gives an estimate based on body signals. It is not a medical device.
