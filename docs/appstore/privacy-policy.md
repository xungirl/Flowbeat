---
title: "Flowbeat Privacy Policy · 心流隐私政策"
---

# Flowbeat Privacy Policy

*Effective date: [publication date] · Applies to Flowbeat 1.x for Apple Watch and iPhone*

Flowbeat ("the app") estimates how focused you are from your heart rate and wrist motion. This policy explains what data the app uses and where it goes. In short: **your data stays on your Apple Watch and your iPhone, plus (if you use iCloud) your own private iCloud database, which never contains heart rate. We don't collect, receive, sell or share any of your data.**

## What the app uses

| Data | Source | Why | Where it is stored |
|---|---|---|---|
| Heart rate | Apple Health (HealthKit), measured by your Apple Watch | To compute the focus estimate during a session | On your watch, inside the app |
| Wrist motion (acceleration) | Apple Watch motion sensors | To compute the focus estimate | On your watch, inside the app |
| Walking / standing activity and step count | Motion & Fitness (CoreMotion) | To pause scoring while you walk away | On your watch, inside the app |
| Your "Focused" / "Distracted" labels | You, in the app | So you can compare the estimate with how you felt | On your watch, inside the app |
| Whether you have seen the introduction screens | The app | So they aren't shown on every launch | On your watch, inside the app |
| Your settings (distraction nudge, Pomodoro lengths, session and daily goals, personalized scoring on/off) | You, in the app | To behave the way you chose | On your watch, inside the app |
| Focus history (focused minutes per minute of past sessions) | Computed from your saved sessions | For the History screen: today, last 7 days, streak, best time of day | On your watch, inside the app |
| A summary for the watch face widget (focused minutes per 15 minutes, last 60 days, and your daily goal) | Computed from your history | So the complication can show today's minutes | On your watch, in a container shared only between the app and its own widget |
| A personal scoring model (a few numbers learned from your labels) | Trained on your watch from your "Focused" / "Distracted" labels | To adapt the estimate to you | On your watch, inside the app; recomputed when needed |

## On your iPhone

When a session ends, the watch sends it to the Flowbeat iPhone app over Apple's WatchConnectivity (directly between your own devices, not through any server of ours).

| Data | Where it is stored |
|---|---|
| Each session with its focus scores, wrist motion, time away, your labels and the note you write on the iPhone | In the app's database on your iPhone. If iCloud is on for Flowbeat, also in **your private iCloud database** (CloudKit), which only your Apple Account can read. The copy that goes to iCloud has **no heart rate and no heart-rate variability**: they are removed before anything is saved to the synced database. |
| The original session file from the watch, including heart rate | Only on your iPhone, in a folder that is excluded from iCloud Backup. Used when you export a session. |
| Your daily goal | On your iPhone and your watch (kept in sync between them) |

Apple stores your iCloud data under your Apple Account; we can't access it. You can turn iCloud sync off in iOS Settings → your name → iCloud, and export your sessions as CSV or JSON from the app.

Siri and Shortcuts can start or stop a session ("Start focus in Flowbeat"). The app only receives the request to start or stop; it doesn't send anything to Siri beyond the short reply shown on screen.

To read your heart rate every few seconds, a focus session runs a "Mind & Body" workout. **The workout is discarded when the session ends and is not saved to Health.** The app doesn't write any other data to Health.

## What we collect

**Nothing.** The app has no account and no sign-in. It contains no analytics, advertising or tracking code, and it does not connect to any server of ours or of any third party. The only data that leaves your devices is the iCloud sync described above, which goes to your own iCloud account and contains no health data. We (the developer) never receive your heart rate, motion data, sessions or any other information. Health data is not used for advertising or marketing, is not sold, and is not shared with any third party.

## Your choices

- You can allow or deny Health and Motion & Fitness access at any time. On iPhone: Health app → Sharing → Apps → Flowbeat. On Apple Watch: Settings → Health, and Settings → Privacy & Security → Motion & Fitness. Without heart-rate access the app can't compute a focus estimate; without Motion & Fitness it works but won't pause while you walk.
- Deleting the app from your watch deletes its data on the watch. Deleting the iPhone app deletes its data on the iPhone; to also remove the iCloud copy, delete the sessions in the app first, or remove Flowbeat's data in iOS Settings → your name → iCloud → Manage Account Storage.
- Deleting a session in the iPhone app removes it from the iPhone and from iCloud.

## Not a medical device

Flowbeat gives an estimate for personal reflection. It does not diagnose, treat or monitor any health condition.

## Children

The app doesn't collect data from anyone, including children.

## Changes

If a future version ever sends any data anywhere other than your own devices and your own iCloud (for example, an optional AI feature), this policy will be updated before that version is released, and the app will ask for your consent before any data leaves the device.

## Contact

Questions about this policy: [contact email]

---

# 心流隐私政策

*生效日期：[发布日期] · 适用于 Apple Watch 和 iPhone 版心流 1.x*

心流（以下称「本 app」）根据你的心率和手腕动作估计你有多专注。本政策说明本 app 使用哪些数据、数据去了哪里。一句话：**数据只留在你的 Apple Watch 和 iPhone 上；如果你使用 iCloud，还会存在你自己的 iCloud 私有数据库里，但那里从不包含心率。我们不收集、不接收、不出售、不分享你的任何数据。**

## 本 app 使用的数据

| 数据 | 来源 | 用途 | 保存位置 |
|---|---|---|---|
| 心率 | Apple「健康」（HealthKit），由你的 Apple Watch 测量 | 专注时计算专注估计 | 你的手表上，本 app 内 |
| 手腕动作（加速度） | Apple Watch 运动传感器 | 计算专注估计 | 你的手表上，本 app 内 |
| 走动 / 静止状态和步数 | 运动与健身（CoreMotion） | 起身走动时暂停计分 | 你的手表上，本 app 内 |
| 你点的「专注」/「走神」标记 | 你在 app 里操作 | 让你对照估计和自己的感受 | 你的手表上，本 app 内 |
| 是否看过介绍页 | 本 app | 避免每次启动都显示 | 你的手表上，本 app 内 |
| 你的设置（走神提醒、番茄钟时长、本次和每日目标、个性化打分开关） | 你在 app 里设置 | 按你的选择工作 | 你的手表上，本 app 内 |
| 专注历史（以往专注每分钟的专注秒数） | 由保存的专注记录计算 | 历史页：今天、最近 7 天、连续达标天数、最专注的时段 | 你的手表上，本 app 内 |
| 表盘小组件用的摘要（最近 60 天每 15 分钟的专注分钟数，以及每日目标） | 由专注历史计算 | 让复杂功能显示今天的分钟数 | 你的手表上，只在本 app 和它自己的小组件之间共享的容器里 |
| 个人打分模型（从你的标记学到的几个数字） | 在手表上用你的「专注」/「走神」标记训练 | 让估计更贴合你 | 你的手表上，本 app 内；需要时重新计算 |

## 在你的 iPhone 上

每次专注结束后，手表通过 Apple 的 WatchConnectivity 把这次记录传给 iPhone 上的心流（在你自己的设备之间直接传输，不经过我们的任何服务器）。

| 数据 | 保存位置 |
|---|---|
| 每次专注的专注分数、手腕动作、离座时间、你的标记，以及你在 iPhone 上写的备注 | 你 iPhone 上本 app 的数据库。如果为心流打开了 iCloud，还会存在**你的 iCloud 私有数据库**（CloudKit）里，只有你的 Apple 账户能读取。同步到 iCloud 的这一份**不含心率和心率变异性**：保存到同步数据库之前就已去掉。 |
| 手表传来的原始记录文件（含心率） | 只在你的 iPhone 上，放在不参与 iCloud 云备份的文件夹里。导出单次记录时使用。 |
| 每日目标 | 你的 iPhone 和手表上（两边保持同步） |

iCloud 中的数据由 Apple 存在你的 Apple 账户下，我们无法访问。你可以在 iOS 设置 → 你的名字 → iCloud 中关闭同步，也可以在 app 里把记录导出为 CSV 或 JSON。

你可以用 Siri 和「快捷指令」开始或结束专注（例如「在心流开始专注」）。本 app 只接收开始 / 结束的请求，除了屏幕上那句简短回复，不会向 Siri 发送任何内容。

为了每隔几秒读取一次心率，专注时会启动一个「身心」类体能训练。**专注结束时这次体能训练会被丢弃，不会存进「健康」。** 本 app 不向「健康」写入任何其他数据。

## 我们收集什么

**什么都不收集。** 本 app 没有账号、不需要登录，不包含任何统计分析、广告或追踪代码，也不连接我们或任何第三方的服务器。唯一离开你设备的数据是上面说的 iCloud 同步：它进入你自己的 iCloud 账户，并且不含任何健康数据。我们（开发者）永远收不到你的心率、动作数据、专注记录或任何其他信息。健康数据不会用于广告或营销，不会出售，也不会分享给任何第三方。

## 你的选择

- 你可以随时允许或拒绝「健康」和「运动与健身」权限。iPhone 上：「健康」App → 共享 → App → 心流。Apple Watch 上：设置 → 健康；设置 → 隐私与安全性 → 运动与健身。没有心率权限时本 app 无法计算专注估计；没有「运动与健身」权限时仍可使用，只是走动时不会自动暂停。
- 从手表上删除本 app，会删除手表上的数据；删除 iPhone 上的 app，会删除 iPhone 上的数据。如果还想删除 iCloud 里的副本，请先在 app 里删除记录，或在 iOS 设置 → 你的名字 → iCloud → 管理账户储存空间 中删除心流的数据。
- 在 iPhone app 里删除一条记录，会同时从 iPhone 和 iCloud 中删除。

## 不是医疗设备

心流给出的是供你自己参考的估计，不做任何诊断、治疗，也不监测任何健康状况。

## 儿童

本 app 不收集任何人的数据，包括儿童。

## 变更

如果将来某个版本需要把任何数据发送到你自己的设备和你自己的 iCloud 以外的地方（例如可选的 AI 功能），我们会在该版本发布前更新本政策，并且在任何数据离开设备之前先在 app 里征得你的同意。

## 联系方式

关于本政策的问题：[contact email]
