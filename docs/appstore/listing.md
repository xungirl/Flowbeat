# App Store listing — Flowbeat v1.0.0 (with the 2026-11-13 features)

Paste-ready text for App Store Connect, in English and Simplified Chinese. Character counts were checked with a script (`len()` on the string). App Store Connect counts **characters** for these fields. The Chinese keywords are also kept under 100 **bytes** in UTF-8, in case any tool counts bytes.

v1 scope: a **watch-only** app that runs fully on-device, with **no network**, no account and no AI judge (see [submission-checklist.md](submission-checklist.md) for why the iPhone companion isn't in v1).

---

## English (U.S.) — primary language

| Field | Text | Length / limit |
|---|---|---|
| Name | `Flowbeat: Focus Score` | 21 / 30 |
| Subtitle | `Focus from heart rate & motion` | 30 / 30 |
| Promotional text | `Start a session, sit down and work. Your watch shows a live 0–100 focus estimate. Everything stays on your wrist.` | 113 / 170 |
| Keywords | `focus,flow,concentration,productivity,deep work,study,pomodoro,heart rate,attention,timer,mindful` | 97 / 100 (already covers Pomodoro; unchanged) |

If the name `Flowbeat` is already taken in App Store Connect, fall back to `Flowbeat – Focus Estimate` (25) or `Flowbeat Focus` (14).

**Description** (≤ 4000)

```
Flowbeat estimates how focused you are while you work or study, using two signals your Apple Watch can read continuously: your heart rate and the motion of your wrist.

HOW IT WORKS
• Tap Start Focus and sit still for one minute while Flowbeat learns your resting heart rate.
• While you work, a ring shows a live 0–100 focus estimate: a still wrist and a heart rate close to your resting level read as focused; fidgeting and an elevated heart rate pull the score down.
• Get up and walk, and Flowbeat notices: the time away is paused instead of being counted as distraction.
• Tap Focused or Distracted at any moment to note how you actually feel.
• End the session to see your average focus, focused minutes, your longest focus streak, time away and steps.

STAY ON TRACK
• Gentle nudge: if you drift for a few minutes, a light tap on your wrist brings you back. Never while you walk, calibrate or take a break, and at most once every few minutes. You choose the timing or turn it off.
• Pomodoro mode: 25-minute work blocks and 5-minute breaks (or your own lengths), with a haptic at each switch. Scoring pauses during breaks.
• Session goal: aim for a number of focused minutes and see whether you made it.

SEE YOUR PROGRESS
• History on your wrist: today's focused minutes, the last 7 days, your daily-goal streak and the time of day you focus best.
• Watch face complications and Smart Stack: today's minutes and progress toward your daily goal.
• Siri and Shortcuts: "Start focus in Flowbeat", "Start a Pomodoro in Flowbeat", "Stop focus in Flowbeat". On Apple Watch Ultra, assign a shortcut to the Action button.

PERSONALIZED, ON YOUR WATCH
• After you have labeled at least 8 focused and 8 distracted moments, Flowbeat trains a small model on your watch from those labels and blends it with the built-in estimate. It shows "Personalized" when it is active, and you can turn it off.

PRIVATE BY DESIGN
• Everything stays on your Apple Watch. No account, no sign-in, no servers, no ads, no tracking.
• Flowbeat reads heart rate from Health. During a session it runs a Mind & Body workout so the watch measures your heart rate every few seconds; the workout is discarded at the end and is not saved to Health.

NOT A MEDICAL DEVICE
Flowbeat gives an estimate for personal reflection. It does not diagnose, treat or monitor any health condition, and the score is not a measurement of attention or of your health.

Requires Apple Watch with watchOS 10 or later.
```

**What's New** (v1.0.0): `First release.` (App Store Connect doesn't show What's New for a first version.)

If v1.0 is ever submitted *without* these features and they ship later as an update, use:

```
• Gentle haptic nudge when you've been distracted for a few minutes (configurable, with a cooldown)
• Pomodoro mode with work/break haptics, plus an optional focused-minutes goal
• History: today, last 7 days, daily-goal streak and your best time of day
• Watch face complications and Smart Stack widget
• Siri and Shortcuts: start or stop a focus session or a Pomodoro
• Personalized scoring trained on your watch from your own labels
```

---

## 简体中文

| 字段 | 文案 | 长度 / 上限 |
|---|---|---|
| 名称 | `心流 Flowbeat：专注指数` | 16 / 30 |
| 副标题 | `用心率和手腕动作估计你的专注` | 14 / 30 |
| 推广文本 | `开始一次专注，坐下工作。手表上实时显示 0–100 的专注估计，所有数据只留在你的手腕上。` | 45 / 170 |
| 关键词 | `专注,心流,学习,效率,番茄钟,心率,注意力,深度工作,计时` | 30 / 100（UTF-8 74 字节） |

**描述**

```
心流根据 Apple Watch 能持续读取的两个信号——心率和手腕动作——估计你在工作、学习时有多专注。

怎么用
• 点「开始专注」，先静坐 1 分钟，心流会记住你平静时的心率。
• 工作时，圆环实时显示 0–100 的专注估计：手腕稳定、心率接近平静水平时分数高；小动作多、心率升高时分数下降。
• 起身走动时会自动识别，离座的时间暂停计分，不算作走神。
• 随时点「专注」或「走神」，记下你自己的真实感受。
• 结束后查看平均专注、专注分钟数、最长连续专注、离座时间和步数。

保持专注
• 轻柔提醒：走神几分钟后手腕轻轻一震，把你拉回来。走路、校准、休息时不会提醒，并且几分钟内最多一次；时长可调，也可以关闭。
• 番茄钟：25 分钟工作、5 分钟休息（也可以自定义），切换时震动提示，休息时暂停计分。
• 本次目标：设定要专注多少分钟，结束时看是否达成。

看见进步
• 手腕上的历史：今天的专注分钟数、最近 7 天、每日目标连续达标天数、一天中最专注的时段。
• 表盘复杂功能和智能叠放：今天的专注分钟数和每日目标进度。
• Siri 和快捷指令：「在心流开始专注」「在心流开始番茄钟」「在心流结束专注」。Apple Watch Ultra 可以把快捷指令设到操作按钮上。

在手表上个性化
• 当你标记了至少 8 次「专注」和 8 次「走神」后，心流会在手表上用这些标记训练一个小模型，并和内置估计混合；启用时显示「个性化」，也可以关闭。

隐私
• 所有数据只保存在你的 Apple Watch 上。没有账号、不用登录、没有服务器、没有广告、不追踪。
• 心流从「健康」读取心率。专注时会启动一个「身心」类体能训练，让手表每隔几秒测一次心率；结束时丢弃，不会存进「健康」。

不是医疗设备
心流给出的是供你自己参考的估计，不做任何诊断、治疗，也不监测任何健康状况；专注指数不是对注意力或健康的测量。

需要 watchOS 10 或更高版本的 Apple Watch。
```

**新功能**：`首次发布。`

如果这些功能以更新的形式发布：

```
• 走神几分钟后轻柔震动提醒（可调时长，有冷却时间）
• 番茄钟模式，工作 / 休息切换时震动；可设定本次专注分钟数目标
• 历史：今天、最近 7 天、每日目标连续达标天数、最专注的时段
• 表盘复杂功能和智能叠放小组件
• Siri 和快捷指令：开始 / 结束专注或番茄钟
• 在手表上用你自己的标记训练的个性化打分
```

---

## Category

- **Primary: Productivity.** The app is a focus/work tool. Putting it under Health & Fitness invites reading it as a health product, which it explicitly isn't.
- **Secondary: Lifestyle.** Health & Fitness is a defensible alternative because the app uses HealthKit. If you pick it, keep every claim non-medical.

## Age rating answers (App Store Connect questionnaire)

Answer **None / No** to every content question:
- Violence (cartoon, realistic, graphic), sexual content or nudity, profanity or crude humor, horror or fear themes: **None**
- Alcohol, tobacco or drug use or references; simulated gambling; contests: **None**
- **Medical or treatment information: None.** The app gives a focus estimate and states that it isn't medical.
- Mature or suggestive themes: **None**
- Unrestricted web access: **No** (there's no network code at all)
- User-generated content, messaging or chat: **No**
- Advertising: **No**
- Gambling (real money): **No**
- Parental controls / age assurance: not applicable

Expected result: **4+**. The questionnaire's exact wording changes over time, so read each question as it appears; the principle is that the app has none of these.

## App Privacy ("nutrition label") draft

- **Data collection: "No, we do not collect data from this app."** → the label shows **Data Not Collected**.
- Why this is accurate for v1: Apple counts data as "collected" when it is transmitted off the device so that you or a third party can access it for longer than it takes to service a request in real time. The v1 binary has **no networking code** (verified by `scripts/verify_release_offline.sh` on every CI run). Heart rate, motion and session files stay in the app's sandbox on the watch.
- Tracking: **No.** No SDKs, no IDFA, no third-party code at all.
- This matches `Flowbeat/PrivacyInfo.xcprivacy` (no collected data types, no tracking).
- **Still accurate with the 2026-11-13 features.** History, the widget snapshot (shared through an App Group with the app's own widget extension on the same watch) and the personalized model are all computed and stored on the watch. Nothing is transmitted, and the Release binary, now including the widget extension, still has no networking code (`verify_release_offline.sh` scans both). Siri/Shortcuts only deliver a start/stop request to the app. None of this counts as "collected".
- **If the AI judge is ever enabled in a release,** this answer changes. 2-minute summaries derived from heart rate and motion would go to your backend and then to a third-party LLM provider. You would declare **Health & Fitness → Health** (and probably **Fitness**) as *collected*, *not linked to identity* (there's no account), *not used for tracking*, purpose *App Functionality*. You would also have to update the privacy manifest and the privacy policy, bump `OnboardingState.currentVersion` so users see the new disclosure, and add a separate in-app consent before any data leaves the watch (guideline 5.1.2/5.1.3).

## URLs

| Field | Value |
|---|---|
| Support URL (required) | `[support URL — e.g. https://xungirl.com/flowbeat/]` |
| Marketing URL (optional) | `[marketing URL]` or leave empty |
| Privacy Policy URL (required for HealthKit apps) | `[privacy policy URL — host docs/appstore/privacy-policy.md, e.g. https://xungirl.com/flowbeat/privacy/]` |
| Copyright | `2026 [your legal name]` |

The support page can be a short page on the blog with the description, the "not a medical device" line and a contact address (`[contact email]`).

## Screenshots

See [screenshots/](screenshots/) and [submission-checklist.md](submission-checklist.md#5-screenshots). They are from the **Release build in the watchOS simulator, in demo mode (simulated sensors; history from a fixed sample week)**, so the numbers are illustrative, not real measurements. 10 per language: focus, summary, 3 onboarding pages, Pomodoro break, summary with goal, history (top and bottom), widget views. Apple Watch allows up to 10 screenshots per size; consider dropping onboarding pages in favor of a **real** complication-on-a-face shot from the device (`10-widgets` renders the widget views inside the app, not on a watch face).
