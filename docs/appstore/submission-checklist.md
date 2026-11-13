# Submission checklist — from "account approved" to "submitted"

Status (2026-11-13): all code, config and docs are done, including the haptic nudge, Pomodoro + goals, history, complications (WidgetKit + App Group), App Intents and personalized scoring. **Nothing has been signed, run on a real Apple Watch, uploaded or submitted.** Do the steps in order. Each one says how you know it's done.

## 0. Decision already made: ship the watch app alone (no iPhone app) in v1

| | Watch-only (`Flowbeat` scheme) — **recommended** | With iPhone companion (`FlowbeatPhone` scheme) |
|---|---|---|
| Guideline 4.2 (minimum functionality) | The watch app is the whole product: live score, calibration, away detection, labels, summary | The iPhone app only lists sessions synced from the watch, plus a bundled sample session. A thin second app is exactly what 4.2 rejections target |
| What's verified | The watch app builds, runs and is screenshotted in the simulator | WatchConnectivity has **never** run, on a real pair or a simulated one. The iOS app has only built in CI |
| Review surface | 1 app, 1 set of screenshots, 1 privacy manifest | 2 apps, iPhone screenshots (6.9" + 6.5"), the iPhone sample-data screen needs explaining |
| Device testing needed | 1 watch | A paired iPhone + watch, plus transfer-failure cases |
| Later | Add the iPhone app in v1.1 once WatchConnectivity works on a real pair | — |

Both are already configured. The two watch targets share all source files and the bundle ID `com.xungirl.flowbeat.watchkitapp`, and differ only in Info.plist:
- `Flowbeat` sets `WKWatchOnly = YES`.
- `FlowbeatWatchCompanion` sets `WKCompanionAppBundleIdentifier = com.xungirl.flowbeat` + `WKRunsIndependentlyOfCompanionApp = YES`.

watchOS refuses to install an app that declares both `WKWatchOnly` and `WKRunsIndependentlyOfCompanionApp` (seen in the simulator).

> ⚠️ **Unverified:** how App Store Connect treats a later move from watch-only to "iOS app + watch app" under the same app record. Before committing to it, check Apple's current docs on adding an iOS app to an existing watch-only app. The bundle IDs are already laid out the way Xcode's templates do (`<ios-id>.watchkitapp`), so no ID change should be needed.

## 1. Team ID → signing (5 min)

1. developer.apple.com → Account → **Membership details** → copy the **Team ID** (10 characters).
2. Paste it into `Config/Signing.xcconfig`: `DEVELOPMENT_TEAM = AB12CD34EF`. Commit it (a Team ID isn't secret).
3. `xcodegen generate && open Flowbeat.xcodeproj`.
4. In the `Flowbeat` target, open **Signing & Capabilities**. It should show your team, "Automatically manage signing", the **HealthKit** capability and **App Groups** with `group.com.xungirl.flowbeat` ticked, with no red errors. Do the same for the `FlowbeatWidgets` target (App Groups only). Xcode registers the App IDs on first build to a device.

✅ Done when an Xcode build to your watch succeeds with automatic signing.

## 2. Register App IDs + HealthKit capability

Automatic signing usually does this for you. Check it at developer.apple.com → Certificates, IDs & Profiles → Identifiers:

- [ ] `com.xungirl.flowbeat.watchkitapp`, with **HealthKit** and **App Groups** checked. Leave "Clinical Health Records" and "Background Delivery" off; neither is used.
- [ ] **App Group `group.com.xungirl.flowbeat`**: Identifiers → "+" → App Groups → description "Flowbeat", identifier `group.com.xungirl.flowbeat`. Then edit both App IDs (watch app and widget) → App Groups → Configure → tick it. Automatic signing can create the group too, but check that it exists under *your* Team ID: the identifier in `project.yml`, both `.entitlements` files and `FlowbeatCore/…/WidgetSnapshot.swift` (`AppGroup.identifier`) must match exactly. If the name is taken, pick another and change all four places.
- [ ] `com.xungirl.flowbeat.watchkitapp.widgets` (widget extension), with **App Groups** checked.
- [ ] (Only if you ship the companion) `com.xungirl.flowbeat`. No capabilities needed.
- [ ] App Store Connect → **My Apps → + New App**: platform **watchOS** (watch-only), name from `listing.md`, primary language English (U.S.), bundle ID as offered for the watch app, SKU e.g. `flowbeat-1`.
  - ⚠️ For a watch-only app, App Store Connect / Xcode may want the record's bundle ID to be the parent (`com.xungirl.flowbeat`) with the watch app inside an Xcode-generated stub. **Not verified locally:** archiving needs signing. If Organizer's validation complains, follow its message on which bundle ID the record needs, and register that ID too.

## 3. Real-device test plan (the most important step)

Build the **Release** configuration to the watch (Product → Scheme → Edit Scheme → Run → Build Configuration: Release), so you test what ships: no AI, no network. Charge the watch to 100 % first. Record every result in the README's Key metrics.

| # | Test | How | Pass |
|---|---|---|---|
| 1 | First launch | Fresh install. Onboarding appears before any system prompt; Continue on the last page triggers Health, then Motion & Fitness | Prompts only after the explanation; text fits in both languages |
| 2 | Health denied | Deny Health on first launch | Start is disabled, the guidance text is correct, "Check again" works after you enable it in Settings. **Write down the real Settings path** and fix the in-app text, `review-notes.md` and `privacy-policy.md` if it differs |
| 3 | Motion denied | Deny Motion & Fitness | You can still start; the warning shows; no away detection |
| 4 | Heart-rate sampling | 10-min session; afterwards inspect the session JSON (Xcode → Devices → Flowbeat → Download Container → `Documents/sessions/`) | HR present in ≥ 90 % of samples after calibration; note the real interval between readings |
| 5 | **30-min session** | Real desk work, wrist down most of the time | The session survives; the summary appears; no crash |
| 6 | **Background survival** | Start, lower the wrist, open another app, come back after 10 min; repeat with the watch locked | The timer kept counting and samples have no gaps |
| 7 | **Battery drain per hour** | Note the battery % at start, run a 60-min session, note it at the end. Repeat once | Record %/hour. Compare with a 60-min Mind & Body workout in Apple's Workout app as a baseline |
| 8 | Workout discarded | After a session, open Fitness and Health → Workouts | **No** Flowbeat workout. Note whether HR samples from that window appear under "Apple Watch" (expected; adjust the wording in the docs if needed) |
| 9 | Away detection | Walk around for 1 min mid-session | The ring shows "Away", time is paused, the summary counts it |
| 10 | Language | Watch language: English, then 简体中文 | All strings localized, nothing truncated; the app name shows as 心流 |
| 11 | About | Tap (i) on the start screen | The disclaimer pages and version 1.0.0 (1) appear |
| 12 | Kill mid-session | Force-quit during a session | Relaunch is clean (no saved session is expected; known limitation) |
| 13 | Airplane mode | Run a session in airplane mode | Identical behavior (the app has no network code) |
| 14 | **Haptic nudge** | Session with wrist down; fidget for 3+ min (or set "After" to 1 min) | One gentle tap after N min, felt with the wrist down; no second tap within the cooldown; none while walking or calibrating. Is `.directionUp` noticeable but not annoying? Record the result |
| 15 | **Pomodoro** | Set work 5 / break 1 min in Settings, start Pomodoro, lower the wrist | Haptic at 5:00 (break) and 6:00 (work) even with the wrist down; break ring shows; summary has no scores during the break |
| 16 | Session goal | Set a 15-min goal, run 20 min | One success haptic when reached; the summary shows "Goal reached" |
| 17 | History | After 2+ sessions on different days | Today / 7-day bars / streak / best time match the sessions; after midnight "today" resets |
| 18 | **Complications** | Add "Focus today" to a face (circular, rectangular, inline, corner) and the Smart Stack | Shows today's minutes; updates within a minute of ending a session; resets after midnight; tap opens Flowbeat; both languages fit |
| 19 | **Siri / Shortcuts** | "Start focus in Flowbeat", "Start a Pomodoro in Flowbeat", "Stop focus in Flowbeat"; 「在心流开始专注」 in 中文; Shortcuts app; Ultra: Settings → Action Button → Shortcut | Each works; Stop saves the session without opening the app |
| 20 | Double tap (Series 9+/Ultra 2, watchOS 11) | During a session, on the controls page, double-tap | Marks "Focused" |
| 21 | Personalized scoring | Label 8+ focused and 8+ distracted moments across sessions | Settings shows "Active" with the top factors; the ring shows "Personalized". Note whether the score feels better or worse (not validated) |

If 5–7 fail (the app is suspended or the battery drain is unacceptable), stop and fix before going further.

## 4. Version check

- [ ] `MARKETING_VERSION = 1.0.0`, `CURRENT_PROJECT_VERSION = 1` (project.yml). Increase `CURRENT_PROJECT_VERSION` for every new upload.

## 5. Screenshots

- Fresh simulator screenshots of the Release build are in `docs/appstore/screenshots/` (10 per language, English + 简体中文), made by `scripts/appstore_screenshots.sh` in **demo mode** (simulated sensors; history is a fixed sample week, not measurements). Screens 6–10 are Pomodoro break, summary with goal, history (two scrolls) and the widget views. The widget shot (`10-widgets`) renders the widget views inside the app; it is **not** a real watch face. For App Store use, prefer a real-device screenshot of the complication on a face.
  - Apple Watch Ultra 2 (49mm): 410 × 502 px.
  - Apple Watch Series 10 (46mm): 416 × 496 px.
- **Check in App Store Connect which watch size it requires now.** At the time of writing, the largest current watch sizes are Ultra 3 (422 × 514) and Series 11 (416 × 496), but the local Xcode 16.3 only has the watchOS 11.4 simulators listed above. **Not verified:** that 410 × 502 / 416 × 496 are still accepted. If ASC asks for 422 × 514, install a newer Xcode / watchOS simulator and rerun the script with that model name in `MODELS`, or take screenshots on the real watch (side button + Digital Crown, synced to the iPhone Photos app).
- Upload the English set to "English (U.S.)" and the 中文 set to "Chinese (Simplified)" (add that localization in ASC first).
- Optional: replace the demo-mode shots with real-device ones after step 3. They're more honest, though the demo numbers aren't misleading in themselves.

## 6. TestFlight

1. Scheme `Flowbeat` → destination **Any watchOS Device (arm64)** → Product → **Archive** (Archive uses Release, so AI is off).
2. Organizer → **Validate App**, then fix anything it reports (icons, Info.plist keys, bundle ID questions from step 2).
3. **Distribute App → App Store Connect → Upload.**
4. Export compliance is answered by `ITSAppUsesNonExemptEncryption = NO` in Info.plist; there should be no prompt.
5. App Store Connect → TestFlight → install through the TestFlight app on your iPhone (watch apps install from there onto the paired watch). Repeat tests 1, 5 and 8 on the TestFlight build.

## 7. App Store Connect metadata

- [ ] Paste the name, subtitle, promotional text, description and keywords from `listing.md` (EN + 中文).
- [ ] Category: Productivity / Lifestyle.
- [ ] Age rating questionnaire as in `listing.md` → 4+.
- [ ] App Privacy: **Data Not Collected**.
- [ ] Privacy Policy URL: host `privacy-policy.md` on the blog, replace `[contact email]` and `[publication date]`, and paste the URL.
- [ ] Support URL.
- [ ] App Review Information: paste `review-notes.md` and replace `[contact email]`. Sign-in required: **No**. Contact phone/email: yours.
- [ ] Pricing: Free. Availability: see China notes below.
- [ ] Select the TestFlight build for version 1.0.0.

## 8. Submit

- [ ] Run the local checks one last time: `swift test --package-path FlowbeatCore`, `cd backend && uv run pytest`, `scripts/verify_release_offline.sh`.
- [ ] **Add for Review → Submit.** Choose manual release if you want to publish the blog/privacy pages first.

## China mainland storefront notes

- **ICP App filing (App 备案) is required** to be available on the China mainland App Store. Since 2024 App Store Connect asks for an ICP filing number when China mainland availability is selected. App filing goes through the MIIT system via a filing service provider, and individuals usually need a mainland ID. If you can't file yet, **untick China mainland** under Pricing and Availability for v1 and ship everywhere else. Adding China later only needs the filing number, not a new build.
- **An offline v1 avoids the generative-AI questions.** Apps that offer generative-AI services to users in mainland China need a generative-AI service filing / approval number before Apple will distribute them there. The v1 binary has no LLM code at all: the AI judge is compiled out, which `verify_release_offline.sh` checks. So this doesn't apply now. **If the AI judge ships later,** expect that requirement for the China storefront, plus the privacy changes listed in `listing.md`.
- The app name `心流` might be taken or trademarked on the China store; `心流 Flowbeat：专注指数` is more distinctive.

## What only the developer can do

1. Paste the Team ID (step 1), and register the App Group `group.com.xungirl.flowbeat` plus the widget App ID under it (step 2).
2. Run the real-device test plan (step 3) and record the results.
3. Host the privacy policy and support page and fill in the contact email.
4. Archive, upload, fill App Store Connect and submit (steps 6–8).
