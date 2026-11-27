# App Review notes — Flowbeat 1.0.0

Paste the block below into **App Store Connect → App Review Information → Notes**. Leave **Sign-in required** unchecked; there is no account.

```
Thank you for reviewing Flowbeat.

WHAT IT IS
An Apple Watch app with an iPhone companion. The watch shows a live 0-100 focus estimate while the user works or studies, computed on the watch from heart rate (HealthKit) and wrist motion (CoreMotion). The iPhone app keeps every session and shows trends. The watch app also works without the iPhone. No medical claims: the first-launch screens state it is not a medical device.

NO ACCOUNT, NO SERVER
No login, no account, no server of ours, no third-party SDK, no networking code of our own. Sessions move watch -> iPhone with WatchConnectivity, are stored with SwiftData and, if iCloud is on, sync to the user's private CloudKit database.

HEALTH DATA AND iCLOUD (5.1.3)
Heart rate is never stored in iCloud. All heart-rate and HRV values are removed before a session is saved to the synced store; only focus scores, motion, time away, labels and notes sync. The file with heart rate stays on the device (excluded from iCloud Backup) and is used only for user export. Health data is not used for advertising or shared.

WHY AN HKWorkoutSession (Mind & Body)
The score needs heart rate every few seconds for 25-90 minutes while the wrist is often lowered. Outside a workout, watchOS samples heart rate only occasionally and the app is suspended. A workout session provides both, so the app uses the "workout-processing" background mode with the Mind & Body type, matching a calm seated activity.
- It runs only between "Start Focus" and "End".
- At the end the workout is discarded (discardWorkout()); no workout is saved to Health (verified on device).
- Health permissions: read Heart Rate; share Workouts (required to start a session). Nothing else is written.
- Motion & Fitness only detects walking, so time away is paused instead of scored. If declined, the app still works.

HOW TO DEMO (about 3 minutes)
1. Open Flowbeat on the watch, read the 4 onboarding pages, tap Continue, allow Health and Motion & Fitness.
2. Tap "Start Focus". A 60-second calibration learns the resting heart rate; sit still.
3. The ring then shows the estimate: still wrist = higher, moving the hand = lower. Lowering the wrist keeps the session running.
4. Scroll to the second page, tap "Focused" or "Distracted", then "End".
5. The summary shows average focus, focused minutes, longest streak, time away and steps. Tap "Done".
6. On the paired iPhone, open Flowbeat: the session appears under Sessions within seconds. Today shows minutes vs the daily goal, 7/30 days and best time of day. Open a session to see its timeline and add a note. Settings -> "Export all as CSV".
   Without a watch: the iPhone shows "View a sample session", a bundled example labeled as sample data.
Optional (all on-device): Pomodoro (25/5 with haptics), a gentle distraction haptic (at most once per 10 min), History, the "Focus today" complication, and Siri: "Start focus in Flowbeat" / "Stop focus in Flowbeat".
If Health is declined, the start screen explains how to enable it and offers "Check again".

Contact: xungirl1024@163.com
```

## Capabilities added after the first draft (2026-11-13)

- **App Group `group.com.xungirl.flowbeat.shared`** (watch app + widget extension): one JSON file the complication reads (today's focused minutes, daily goal). Same device, no network. Must be registered under the Team ID before archiving (see the checklist).
- **WidgetKit extension** (`com.xungirl.flowbeat.watch.widgets`): accessory complications / Smart Stack. Static timeline (now + next midnight), reloaded by the app when a session ends.
- **App Intents / App Shortcuts:** no SiriKit entitlement is needed for App Shortcuts. The start intents open the app because the workout session must start in the foreground; Stop runs in the background while a session is active.
- **Not used:** `StartWorkoutIntent` (the Ultra Action button's workout slot). Flowbeat isn't a workout app, so it doesn't claim that slot; Ultra users can still bind the "Start Focus" shortcut via Settings → Action Button → Shortcut.
- **Haptics:** `WKInterfaceDevice.play` only while a session is in the foreground or running as a workout session; no notifications are used.

## Why each point is there (for us, not for Review)

- **Guideline 2.5.4 (background modes for their intended purpose)** is the main risk. `workout-processing` is meant for workouts. Mind & Body is a real HealthKit activity type that meditation and breathing apps use, and a seated focus session is close to that. The note explains the purpose up front so the reviewer doesn't have to guess. **If it's rejected anyway**, the fallback is a `WKExtendedRuntimeSession` (the *mindfulness* type allows up to 1 h) without a workout. That would mean much sparser heart rate, so the score would lean on wrist motion. It's a real product trade-off, not just a config change.
- **Guideline 5.1.3 (HealthKit):** a privacy policy URL is required; health data isn't used for advertising or stored in iCloud; it isn't shared with third parties. All true in v1 (see 5.1.3(ii) below for how iCloud is kept free of heart rate).
- **Guideline 1.4.1 (medical apps):** no claims of measuring attention or health; the disclaimer is in the app, the description and the policy.
- **Guideline 4.2 (minimum functionality):** the watch app (live score, calibration, away detection, labels, summary) carries the product. The iPhone app was a thin list in the first draft, which is why v1 was watch-only; since 2026-11-22 it has its own value: 7/30-day trends, best hour, streak, notes and search, CSV/JSON export, goal sync and iCloud restore. The sample-session button covers a reviewer without a watch.
- **Guideline 5.1.3(ii) (no personal health information in iCloud):** handled in code, not just in text: `SessionRecord.withoutHealthData()` runs before every write to the CloudKit-backed store, and a unit test asserts the stored record has no heart rate.
- The **demo steps** must match the real build. Re-check them on a real watch before submitting; the 60 s calibration is the device value (the simulator uses 10 s).

## Things to verify on a real watch before pasting this

**Verified on a real Apple Watch S9, 2026-11-27, with the devtest Release build installed 2026-11-22 (`com.xungirl.flowbeat.devtest.*`, not the TestFlight build):** sessions save on the watch; the timer keeps running with the wrist lowered, in another app and with the watch locked; walking shows "Away"; **no Flowbeat workout appears in Health → Activity → Workouts after "End"** (discardWorkout works). Watch → iPhone sync was **not** verified (the devtest watch app had no devtest iPhone app to send to). The items below that are not covered by this list are still open.

- The workout really is absent from the Fitness and Health apps after "End". The code calls `discardWorkout()`, but this has only run in the simulator. Heart-rate samples that the watch measures during the session may still show up in Health under "Apple Watch", as for any workout; check what appears and adjust the wording if needed.
- The exact Settings path for re-enabling Health access on watchOS and in the iPhone Health app. The in-app text says *Health app on iPhone → Sharing → Apps → Flowbeat* or *Settings → Health on the watch*.
- The session keeps running with the wrist lowered for 30+ minutes.
- The nudge and Pomodoro haptics are felt with the wrist lowered (background workout session) and are gentle enough.
- The complication appears in the watch face editor, shows today's minutes after a session and resets after midnight.
- "Start focus in Flowbeat" works with Siri on the watch in English and Chinese (「在心流开始专注」).
