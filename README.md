# Flowbeat · 心流

**Flowbeat** is an Apple Watch app that estimates whether you're in a state of focus ("flow") from your **heart rate** and **wrist motion**, and shows it as a live 0–100 focus score.

> Flowbeat 是一款 Apple Watch app：通过**心率**和**手腕动作**判断你是否进入了「心流」专注状态，实时给出 0–100 的专注指数。

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

Optional env: `CLAUDE_MODEL` (default `claude-haiku-5-5`), `LLM_PROVIDER=claude|fake`, `FLOWBEAT_TOKEN` (shared secret; set the same value in `AIConfig.token`). The simulator talks to `localhost:8765`; for a real watch set `AIConfig.baseURL` in `Flowbeat/AIJudge.swift` to your Mac's `.local` name on the same Wi-Fi.

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
