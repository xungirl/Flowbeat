# App Review notes — Flowbeat 1.0.0

Paste the block below into **App Store Connect → App Review Information → Notes**. Leave **Sign-in required** unchecked; there is no account.

```
Thank you for reviewing Flowbeat.

WHAT IT IS
Flowbeat is a standalone Apple Watch app (no iPhone app) that shows a live 0–100 focus estimate while the user works or studies. The estimate is computed on the watch from two signals: heart rate (HealthKit) and wrist motion (CoreMotion device motion). The app makes no medical claims, and the first-launch screens state that it is not a medical device and does not diagnose anything.

NO ACCOUNT, NO NETWORK
There is no login, no account, no server and no third-party SDK. The app contains no networking code; all data stays in the app's sandbox on the watch.

WHY AN HKWorkoutSession (Mind & Body)
The score needs heart-rate readings every few seconds for the whole focus session (typically 25–90 minutes). Outside a workout, watchOS samples heart rate only occasionally. While the session is active, the user often lowers the wrist, and the app needs to keep running in the background. A workout session is the supported way to get both, so the app declares the "workout-processing" background mode and uses the Mind & Body activity type, which matches a seated, calm activity.
- The workout session runs only between the user tapping "Start Focus" and "End".
- When the session ends, the workout is discarded (HKLiveWorkoutBuilder.discardWorkout()). No workout is saved to Health.
- Health permissions requested: read Heart Rate; share Workouts (required to start a workout session). Nothing else is written to Health.
- Motion & Fitness is used only to detect walking, so that time away from the desk is paused instead of being scored as distraction. If the user declines it, the app still works and says that walking won't pause scoring.

HOW TO DEMO (about 3 minutes)
1. Launch Flowbeat on the watch. Read the 4 onboarding pages (scroll with the Digital Crown) and tap Continue on the last one. Allow Health (heart rate + workouts) and Motion & Fitness.
2. On the start screen, tap "Start Focus". The ring shows a 60-second calibration countdown; sit still while it learns the resting heart rate.
3. After calibration the ring shows the focus estimate. Keep the wrist still for a high score, or move the hand around for a lower one. Lowering the wrist keeps the session running.
4. Scroll down (Digital Crown) to the second page. Tap "Focused" or "Distracted" to label the moment, then tap "End".
5. The summary shows average focus, time in flow, focused minutes, longest focus streak, time away and steps. Tap "Done".
6. The (i) button on the start screen reopens the "About" / not-a-medical-device screens.
7. Optional features (all on-device):
   - "Pomodoro" on the start screen: 25/5 work/break blocks with a haptic at each switch; scoring pauses during breaks. Lengths and an optional focused-minutes goal are in Settings (gear icon).
   - Distraction nudge (on by default, Settings): after 3 minutes of a low score the watch plays one light haptic, at most once every 10 minutes, never while walking, calibrating or on a break.
   - "History" on the start screen: today, last 7 days, daily-goal streak, best time of day.
   - Watch face: add the "Focus today" complication (Flowbeat) to see today's focused minutes; tapping it opens the app.
   - Siri / Shortcuts: "Start focus in Flowbeat", "Start a Pomodoro in Flowbeat", "Stop focus in Flowbeat".
If Health access is declined in step 1, the start screen explains how to turn it on and offers "Check again"; the app does not crash or dead-end.

Contact: [contact email]
```

## Capabilities added after the first draft (2026-11-13)

- **App Group `group.com.xungirl.flowbeat`** (watch app + widget extension): one JSON file the complication reads (today's focused minutes, daily goal). Same device, no network. Must be registered under the Team ID before archiving (see the checklist).
- **WidgetKit extension** (`com.xungirl.flowbeat.watchkitapp.widgets`): accessory complications / Smart Stack. Static timeline (now + next midnight), reloaded by the app when a session ends.
- **App Intents / App Shortcuts:** no SiriKit entitlement is needed for App Shortcuts. The start intents open the app because the workout session must start in the foreground; Stop runs in the background while a session is active.
- **Not used:** `StartWorkoutIntent` (the Ultra Action button's workout slot). Flowbeat isn't a workout app, so it doesn't claim that slot; Ultra users can still bind the "Start Focus" shortcut via Settings → Action Button → Shortcut.
- **Haptics:** `WKInterfaceDevice.play` only while a session is in the foreground or running as a workout session; no notifications are used.

## Why each point is there (for us, not for Review)

- **Guideline 2.5.4 (background modes for their intended purpose)** is the main risk. `workout-processing` is meant for workouts. Mind & Body is a real HealthKit activity type that meditation and breathing apps use, and a seated focus session is close to that. The note explains the purpose up front so the reviewer doesn't have to guess. **If it's rejected anyway**, the fallback is a `WKExtendedRuntimeSession` (the *mindfulness* type allows up to 1 h) without a workout. That would mean much sparser heart rate, so the score would lean on wrist motion. It's a real product trade-off, not just a config change.
- **Guideline 5.1.3 (HealthKit):** a privacy policy URL is required; health data isn't used for advertising or stored in iCloud; it isn't shared with third parties. All true in v1.
- **Guideline 1.4.1 (medical apps):** no claims of measuring attention or health; the disclaimer is in the app, the description and the policy.
- **Guideline 4.2 (minimum functionality):** a standalone watch app with a live score, calibration, away detection, labels and a summary is more than a single-screen wrapper. Shipping the iPhone app as well would add a second surface that only shows a list, which is the riskier part (see the checklist).
- The **demo steps** must match the real build. Re-check them on a real watch before submitting; the 60 s calibration is the device value (the simulator uses 10 s).

## Things to verify on a real watch before pasting this

- The workout really is absent from the Fitness and Health apps after "End". The code calls `discardWorkout()`, but this has only run in the simulator. Heart-rate samples that the watch measures during the session may still show up in Health under "Apple Watch", as for any workout; check what appears and adjust the wording if needed.
- The exact Settings path for re-enabling Health access on watchOS and in the iPhone Health app. The in-app text says *Health app on iPhone → Sharing → Apps → Flowbeat* or *Settings → Health on the watch*.
- The session keeps running with the wrist lowered for 30+ minutes.
- The nudge and Pomodoro haptics are felt with the wrist lowered (background workout session) and are gentle enough.
- The complication appears in the watch face editor, shows today's minutes after a session and resets after midnight.
- "Start focus in Flowbeat" works with Siri on the watch in English and Chinese (「在心流开始专注」).
