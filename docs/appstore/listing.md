# App Store listing — Flowbeat v1.0.0

Paste-ready text for App Store Connect, in English and Simplified Chinese. Character counts were checked with a script (`len()` on the string). App Store Connect counts **characters** for these fields. The Chinese keywords are also kept under 100 **bytes** in UTF-8, in case any tool counts bytes.

v1 scope: a **watch-only** app that runs fully on-device, with **no network**, no account and no AI judge (see [submission-checklist.md](submission-checklist.md) for why the iPhone companion isn't in v1).

---

## English (U.S.) — primary language

| Field | Text | Length / limit |
|---|---|---|
| Name | `Flowbeat: Focus Score` | 21 / 30 |
| Subtitle | `Focus from heart rate & motion` | 30 / 30 |
| Promotional text | `Start a session, sit down and work. Your watch shows a live 0–100 focus estimate. Everything stays on your wrist.` | 113 / 170 |
| Keywords | `focus,flow,concentration,productivity,deep work,study,pomodoro,heart rate,attention,timer,mindful` | 97 / 100 |

If the name `Flowbeat` is already taken in App Store Connect, fall back to `Flowbeat – Focus Estimate` (25) or `Flowbeat Focus` (14).

**Description** (≤ 4000)

```
Flowbeat estimates how focused you are while you work or study, using two signals your Apple Watch can read continuously: your heart rate and the motion of your wrist.

HOW IT WORKS
• Tap Start Focus and sit still for one minute while Flowbeat learns your resting heart rate.
• While you work, a ring shows a live 0–100 focus estimate: a still wrist and a heart rate close to your resting level read as focused; fidgeting and an elevated heart rate pull the score down.
• Get up and walk, and Flowbeat notices: the time away is paused instead of being counted as distraction.
• Tap Focused or Distracted at any moment to note how you actually feel.
• End the session to see your average focus, time in flow, time away and steps.

PRIVATE BY DESIGN
• Everything stays on your Apple Watch. No account, no sign-in, no servers, no ads, no tracking.
• Flowbeat reads heart rate from Health. During a session it runs a Mind & Body workout so the watch measures your heart rate every few seconds; the workout is discarded at the end and is not saved to Health.

NOT A MEDICAL DEVICE
Flowbeat gives an estimate for personal reflection. It does not diagnose, treat or monitor any health condition, and the score is not a measurement of attention or of your health.

Requires Apple Watch with watchOS 10 or later.
```

**What's New** (v1.0.0): `First release.`

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
• 结束后查看平均专注、心流占比、离座时间和步数。

隐私
• 所有数据只保存在你的 Apple Watch 上。没有账号、不用登录、没有服务器、没有广告、不追踪。
• 心流从「健康」读取心率。专注时会启动一个「身心」类体能训练，让手表每隔几秒测一次心率；结束时丢弃，不会存进「健康」。

不是医疗设备
心流给出的是供你自己参考的估计，不做任何诊断、治疗，也不监测任何健康状况；专注指数不是对注意力或健康的测量。

需要 watchOS 10 或更高版本的 Apple Watch。
```

**新功能**：`首次发布。`

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

See [screenshots/](screenshots/) and [submission-checklist.md](submission-checklist.md#5-screenshots). They are from the **Release build in the watchOS simulator, in demo mode (simulated sensors)**, so the numbers are illustrative, not real measurements.
