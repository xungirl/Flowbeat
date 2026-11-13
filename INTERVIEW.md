# Flowbeat 面试准备手册（中文）

> 这份文档带你按「教学顺序」把 Flowbeat 的代码一个文件一个文件读懂，再给出约 20 道面试官可能问的问题和基于这份代码的回答。
> 每个文件分三层：**(a) 骨架**：它做什么；**(b) 为什么**：为什么这样设计；**(c) 语法**：用到的 SwiftUI / HealthKit / CoreMotion / WatchConnectivity / Python 语法。
> 力气花在前两层，语法层看懂即可。
>
> **先说清楚边界（面试时主动讲）：** 这个 app **从没在真手表上跑过**。所有端到端验证都在 watchOS 模拟器的演示模式里（传感器是模拟的）；iPhone app 只在 GitHub Actions 的 iOS 模拟器上构建、截图过；专注分数**没有**和任何真实标注数据比对过。下面写的每一个数字都能在仓库里找到出处。

---

## 0. 全局图：数据怎么流动

```
手表（离线也能用）                                后端（FastAPI）                    LLM（通义千问）
HealthKit 心率 ─┐                                ┌─────────────────────┐
CoreMotion 加速度 ├─ 每秒 FocusEngine.tick ─ 圆环分数   │ /v1/judge           │── 超时/重试 ──▶ qwen3.8-flash
走路/跑步 → 离座 ─┘        │                     │  校验 → 口令 →       │◀── 失败就按规则分兜底
                       每 2 分钟 WindowSummary ──▶│  LLM 或 fallback      │
                       （只发统计量）  JudgeSync 队列│ /v1/review（结束时）  │
                       离线就排队、退避重试 ◀────────│ /healthz             │
                       结束 → SessionRecord JSON   └─────────────────────┘
                              │ WatchConnectivity transferFile
                              ▼
                       iPhone：Swift Charts 时间线
```

三层分工：
1. **手表本地规则**（每秒）：透明、离线、不花钱。
2. **LLM 第二意见**（每 2 分钟）：拿你自己的标注做 few-shot，给个性化判断和一句理由。
3. **iPhone**（结束后）：看整段曲线。

代码分成三块：
- `FlowbeatCore/`：Swift Package，**纯逻辑**（没有传感器、没有 UI），macOS 上 `swift test`、watchOS 模拟器上 `xcodebuild test` 都能跑。
- `Flowbeat/`（手表 app）和 `FlowbeatPhone/`（iPhone app）：只负责传感器、网络、界面，逻辑都调 Core。
- `backend/`：FastAPI + uv。

---

## 第一部分：Swift 纯逻辑（FlowbeatCore）

### 1. `FlowbeatCore/Sources/FlowbeatCore/FocusScorer.swift`：规则打分

**(a) 骨架**
- 校准：前 60 秒收集心率，取**中位数**当你的平静基线（`finishCalibration`）。
- 动作扣分：`motionPenalty` = clamp((加速度 − 0.02g) / 0.13g) × 60，最多扣 60。
- 心率扣分：`hrPenalty` = clamp((心率 − 基线 − 5) / 15) × 40，最多扣 40。
- 原始分 = 100 − 两项扣分；再做**指数平滑**：`next = prev + 0.2 × (raw − prev)`。
- `RollingMean`：固定长度滑动平均，把 25 Hz 加速度压成「最近 10 秒平均动作」。

**(b) 为什么**
- **为什么用规则不用模型？** 一开始没有任何标注数据，训练不了。规则透明、可解释、能单测，以后有数据了再换模型（打分逻辑隔离在一个 struct 里，就是为了以后好换）。
- **为什么中位数？** 校准期里偶尔站起来一次，心率冲到 120，均值会被拉高，中位数不会（`testCalibrationUsesMedianNotMean`）。
- **为什么有死区（0.02g、+5 bpm）？** 手腕永远有微小噪声、心率永远有小波动，不设死区分数会一直抖。
- **为什么动作权重 60 > 心率 40？** 动作是更直接的分心信号（玩手机、抖腿）。心率升高也可能是「紧张但专注」，不能扣太多。
- **为什么指数平滑、α=0.2？** 一秒甩一下手不应该让圆环从 100 掉到 40；α=0.2 时一次尖峰最多拉低 12 分（`testSingleSpikeIsDampened`），持续变化约 10 秒后基本跟上。
- 阈值全部是 `static let` 常量，测试和 README 引用同一组数。

**(c) 语法**
- `struct` + `mutating func`：值类型，修改自身状态的方法要标 `mutating`。
- `private(set) var baselineHR`：外面能读、只有自己能写。
- `smoothed.map { ... } ?? raw`：可选值的 `map`，有值就变换，没值用默认。
- `static func`：不依赖实例状态的纯函数，测试直接调 `FocusScorer.motionPenalty(0.085)`。

### 2. `FocusEngine.swift`：每秒的流程 + 离座状态机

**(a) 骨架**
- `AwayTracker`：离座状态机。只在状态**真的变化**时计一次（重复的 walking 事件不 +1）；坐回来时记下时间，之后 60 秒是**恢复期**（`isRecovering`），不按心率扣分。
- `FocusEngine.tick(elapsed:heartRate:motion:)`：
  - 校准期：不走动时才收集心率；到 60 秒且有心率 → 切到打分。没有心率就继续校准（不会拿空数据算基线）。
  - 打分期：离座就只计离座秒数、不打分；否则（恢复期内把心率当 nil）调 scorer 打分。
  - 返回 `Tick(sampleScore:didFinishCalibration:)`。
- `SessionStats`：平均分、分数 ≥ 70 的时间占比。

**(b) 为什么**
- **为什么从 `FocusSession` 里抽出来？** 原来这段逻辑和 HealthKit、Timer、`@Published` 混在一个类里，没法测。抽成纯 struct 后，校准、离座、恢复期这些边界都有单元测试（`FocusEngineTests` 共 9 个）。
- **为什么离座不算走神？** 起身倒水不是走神；离座时间也不计入专注占比和校准基线。
- **为什么有 60 秒恢复期？** 走回座位后心率要一会儿才降下来，这段扣心率分是冤枉的（`testNoHeartRatePenaltyDuringRecoveryGrace`）。

**(c) 语法**
- `@discardableResult`：调用方可以不用返回值，不报警告。
- `enum Phase: String, Codable`：带原始值的枚举，可直接序列化。
- `switch phase { case .calibrating: ... }`：Swift 的 switch 必须穷举。

### 3. `Models.swift`：手表 ↔ 后端的数据格式

**(a) 骨架**
- `FocusSample`（一秒一条）、`SessionRecord`（整次存档，含 `timeline`）、`WindowSummary`（2 分钟摘要）、`Judgment`、`Review`、`JudgeRequest`、`ReviewRequest`、`LabeledExample`。
- `WindowSummary.make(from:baseline:sessionStart:hrv:)`：把逐秒样本压成统计量：心率均值/最小/最大/趋势、动作均值/最大、静止占比（< 0.03g）、离座秒数、规则平均分、可选 HRV。
- `FlowbeatJSON`：和后端通信用 snake_case 编解码器；存档用 ISO 8601 日期。
- `LabeledExample.appending`：标注例子只留最近 20 条（后端也限制 20 条）。

**(b) 为什么**
- **隐私**：只发统计量，**不发原始心率序列和加速度**。服务器上看不到你每一秒的身体数据。
- **为什么还发 `rule_score_mean`？** 存档、复盘、以及后端兜底（LLM 挂了时按它给结果）要用；但后端默认**不放进 LLM 提示词**（见锚定偏差）。
- **可选字段 nil 就不出现在 JSON 里**，后端当「缺失」处理，而不是收到一个 0。HRV 没有时如果发 0，模型会误以为 HRV 极低。
- **契约测试**：`contract_fields.json` 由后端 `scripts/export_contract.py` 从 Pydantic 模型导出；Swift 测试检查编码后的 key 集合等于它，Python 测试检查 Pydantic 字段等于它。两边任何一边改字段名，CI 就红。
- `JudgedWindow.endSeconds`：判断离线排队后可能晚到，靠它放回时间轴的正确位置。

**(c) 语法**
- `Codable`：自动生成编解码；`keyEncodingStrategy = .convertToSnakeCase` 把 `hrMean` 变成 `hr_mean`。
- 可选属性的合成 `Codable` 用 `encodeIfPresent`，nil 不输出。
- `Sendable`：值可以安全地跨并发域（actor）传递；`Hashable` 让 `WindowSummary` 能当字典 key。
- `compactMap(\.heartRate)`：key path 当函数用，过滤 nil。
- 自定义 `public init`：public struct 的成员初始化器默认是 internal，跨模块要自己写。

### 4. `HRV.swift`：可选的心率变异性

**(a) 骨架**
- `HRVSummary.latest(from:at:lookback:)`：在窗口结束前 6 小时内、5–250 ms 合理范围内，取**最新**一个 SDNN 读数，返回「数值 + 距今几分钟」；没有就 nil。
- 摘要里对应 `hrv_sdnn_ms`、`hrv_age_min`，没有就不发。

**(b) 为什么**
- Apple Watch 只在后台**偶尔**测 SDNN（一天几次），2 分钟窗口里几乎不会有新读数，所以不能算「窗口平均」，只能给「最近一次 + 多久之前」，让模型自己掂量。提示词里也写明它是弱参考。
- 没授权时 HealthKit **不报错，只返回空结果**（隐私设计，app 无法知道用户拒绝了读取），所以「没授权」和「没读数」统一处理成 nil。
- **未验证**：模拟器里没有 HRV 数据，真机上读不读得到、多久一次都没测过。

**(c) 语法**
- `ClosedRange`：`5.0...250.0` 和 `.contains(x)`。
- `max(by:)`：按日期取最新。

### 5. `OfflineQueue.swift`：离线容忍

**(a) 骨架**
- `RetryPolicy`：第 n 次连续失败后等 `15 × 2^(n−1)` 秒，封顶 300 秒；同一条最多试 8 次。
- `OfflineQueue<Item>`：先进先出、容量 30（满了丢最老的）、最长保留 1 小时、**队列级**退避（`nextAttemptAt`）。
- `HTTPStatusError`：4xx（除 408、429）是永久错误，直接丢弃，不进入退避。
- `JudgeSync`（actor）：所有判断请求都先入队再 `flush`。在线时等于直接发；离线时停在第一个临时失败上，等退避到期再按顺序重发。

**(b) 为什么**
- **为什么是队列级退避而不是每条各自退避？** 后端挂了时所有请求都会失败，每条各自计时会把整条队列挨个试一遍，手表上白白耗电、耗流量。
- **为什么严格按顺序（队头阻塞）？** 判断要按时间顺序进存档和复盘。
- **为什么永久错误直接丢？** 422（数据被校验拒绝）重试 100 次也是 422，不能让一条坏数据堵住后面所有窗口。另外每条最多 8 次，防止「毒消息」。
- **为什么不加随机抖动（jitter）？** jitter 是为了避免成千上万客户端同时重试造成惊群；这里是一块手表对一个后端，不需要。面试时可以主动说这是有意的取舍。
- **为什么用 actor？** `submit` 里 `await send(...)` 时会挂起，另一个 `submit` 可能同时进来；actor + `isFlushing` 标记保证同一条不会被发两遍（`testConcurrentSubmitsNeverSendTheSameWindowTwice`）。
- **局限**：队列只在内存里，app 被杀掉时没发出去的判断就丢了（窗口本身还在 `SessionRecord.windows` 里）。

**(c) 语法**
- 泛型 `struct OfflineQueue<Item: Codable & Equatable & Sendable>`：协议组合约束。
- `actor JudgeSync`：actor 内部状态一次只被一个任务访问，外部调用要 `await`。
- `catch let e as HTTPStatusError where e.isPermanent`：带类型和条件的 catch。
- `@Sendable` 闭包：可以跨并发域调用的闭包类型。
- 一个踩过的坑：`entries.removeAll { ... maxAge ... }` 里闭包读 `self.maxAge` 会和 `removeAll` 对 `self.entries` 的独占修改冲突（Swift 的 exclusivity 检查直接编译报错），要先拷到局部变量。

### 6. `SessionTimeline.swift` 和 `SessionArchive.swift`：给 iPhone 用的纯逻辑

**(a) 骨架**
- `SessionTimeline(record:)`：分数按 10 秒分桶取平均；离座/校准没有分数的地方把曲线断成多段（`segment`）；标签、离座区间、AI 判断都换算成分钟。
- `SessionArchive`：收到手表的 JSON 先**校验能解析**，再拷进 `Documents/sessions/`；同名覆盖；只取文件名防止 `../` 路径穿越；读出时按开始时间倒序，坏文件跳过。

**(b) 为什么**
- 1 小时有 3600 个点，直接画图又密又慢，所以分桶。
- 不分段的话，Swift Charts 会把离座前后两个点用直线连起来，看起来像「离座期间分数在变化」，这是误导。
- `WCSessionFile` 的临时文件在回调返回后就会被系统删掉，必须同步拷走。
- 旧存档没有 `timeline` 字段时按顺序和 `windows` 对齐（尽力而为），保证向后兼容。

**(c) 语法**
- `Identifiable`：SwiftUI `ForEach` / Charts 需要稳定的 id。
- `Dictionary(default:)`：`buckets[b, default: []].append(score)`。
- `zip(a, b).enumerated()`：成对遍历。

---

## 第二部分：手表 app（Flowbeat/）

### 7. `Flowbeat/FocusSession.swift`：传感器、计时器、网络的总调度

**(a) 骨架**
- `requestAuthorization()`：请求 HealthKit 读心率、HRV，写 workout。
- `start()`：建 `HKWorkoutSession`（类型 mindAndBody）+ `HKLiveWorkoutBuilder`，开始收集心率；启动 CoreMotion（25 Hz 加速度）、活动识别（走路/跑步 → 离座）、计步；每秒 `tick()`。
- `tick()`：算最近 10 秒平均动作 → `engine.tick(...)` → 记一条样本 → 每 120 秒（模拟器 30 秒）发一个窗口给 `JudgeSync` → 离线时每 5 秒检查一次退避是否到期 → 每 5 分钟刷新一次 HRV。
- `stop()`：结束 workout 并 `discardWorkout()`（不往「健康」里写一条假锻炼）→ 最后 flush 一次队列 → 请求复盘 → 存 JSON → 通过 `PhoneSync` 发给 iPhone。
- `mark(_:)`：打标签，同时把最近 60 秒存成一条 few-shot 例子。
- 模拟器专用：`simulateSensors()` 按 60 秒循环造数据（专注 35 秒 → 走神 10 秒 → 走路 15 秒）；`-demo` 跳过 HealthKit/CoreMotion 权限弹窗，`-demoLabels` 自动打标签，`-demoStopAfter N` 自动结束。

**(b) 为什么**
- **为什么要开 workout 才能拿心率？** watchOS 平时只是每隔几分钟测一次心率；只有在 workout 进行中，心率传感器才会每隔几秒连续测，而且 app 放下手腕后还能在后台继续运行（Info.plist 里 `WKBackgroundModes: workout-processing`）。选 mindAndBody 类型、结束时丢弃，不污染用户的健康数据。
- **为什么授权后要再查一次状态？** 用户关掉弹窗或点「不允许」时，`requestAuthorization` **不抛错**。不自己查的话，workout 会开起来但没有数据（Project Journey 第 2 阶段踩过的坑）。HRV 不在检查范围里：它是可选的。
- **为什么离线时每 5 秒才看一次？** `flush()` 在退避期内直接返回、不发请求；5 秒一次的检查几乎没有成本。
- 演示模式跳过权限：模拟器里传感器本来就是假的，权限弹窗只会挡住自动化 demo。真机代码路径不受影响（`#if targetEnvironment(simulator)`）。

**(c) 语法**
- `final class FocusSession: NSObject, ObservableObject`：`@Published` 属性变化时 SwiftUI 自动刷新；继承 `NSObject` 是因为要当 HealthKit 的 delegate。
- `HKWorkoutSession(healthStore:configuration:)`、`associatedWorkoutBuilder()`、`HKLiveWorkoutDataSource`、`beginCollection(at:)`。
- `HKLiveWorkoutBuilderDelegate.workoutBuilder(_:didCollectDataOf:)` → `statistics(for:)?.mostRecentQuantity()` → `doubleValue(for: .count().unitDivided(by: .minute()))` 得到 bpm。
- `HKSampleQuery`（HRV）：`predicateForSamples(withStart:end:)` + `NSSortDescriptor` 倒序 + `limit: 10`；单位 `HKUnit.secondUnit(with: .milli)`。
- `CMMotionManager.startDeviceMotionUpdates(to: .main)` 拿 `userAcceleration`（已经去掉重力），模长 √(x²+y²+z²)。
- `CMMotionActivityManager.startActivityUpdates`：`walking/running/stationary` + `confidence`。
- `Timer.scheduledTimer(withTimeInterval: 1, repeats: true)` + `[weak self]` 防循环引用。
- `await MainActor.run { ... }`、`@MainActor private func`：UI 状态只在主线程改。
- `#if targetEnvironment(simulator)`：编译期条件，真机二进制里根本没有模拟代码。

### 8. `Flowbeat/AIJudge.swift`：网络和标注存储

**(a) 骨架**
- `AIConfig`：后端地址（模拟器 `localhost:8765`，真机填 Mac 的 `.local` 名）、口令、判断间隔。
- `AIClient.post`：JSON POST，带 `X-Flowbeat-Token`；非 200 抛 `HTTPStatusError(code)`，连不上抛 `URLError`。
- `LabelStore`：用 `UserDefaults` 存最近 20 条标注例子，跨 session 保留。

**(b) 为什么**
- **API key 永远不在手表上**：手表只知道后端地址和一个共享口令；LLM 的 key 在后端 `.env`（git-ignored）。
- 抛不同类型的错误，`JudgeSync` 才能区分「丢弃」还是「排队重试」。
- 标注例子存在手表上、跟着请求发，后端是无状态的，不需要数据库。

**(c) 语法**
- `URLSession.shared.data(for:)`：async/await 版网络请求。
- 泛型函数 `post<In: Encodable, Out: Decodable>`。

### 9. `Flowbeat/PhoneSync.swift`：WatchConnectivity

**(a) 骨架**：激活 `WCSession`；存档写好后 `transferFile(url, metadata:)` 发给 iPhone；激活完成前要发的文件先排着，激活后补发；没装 iPhone 端就不发。

**(b) 为什么用 `transferFile` 不用 `sendMessage`？** `sendMessage` 要求 iPhone app 此刻可达，手机不在身边就失败；`transferFile` 由系统排队、后台传输，重新连上再送，app 被杀也不丢。这和「离线也能用」的整体设计一致。
**局限**：传输失败时系统不自动重试，v1 也没有补发旧文件。**WatchConnectivity 在真机配对上从没测过**，模拟器里也没测（这台机器没有 iOS 模拟器运行时）。

**(c) 语法**：`WCSession.isSupported()`、`WCSession.default.delegate`、`activate()`、`WCSessionDelegate` 的 `activationDidCompleteWith`、`didFinish fileTransfer`。

### 10. `Flowbeat/ContentView.swift` + `FlowbeatApp.swift`：界面

**(a) 骨架**：`ContentView` 按 phase 切三屏：开始、进行中、总结。进行中是**上下翻页**：第 1 页圆环 + 心率 + 动作 + AI 理由，第 2 页「专注 / 走神」标签按钮和结束按钮。AI 那一行在离线排队时优先显示「AI 离线 · 排队 N 条」。

**(b) 为什么**：手表屏幕小，看数据和操作分两页；颜色和分数段一致（≥70 薄荷绿、40–70 黄、<40 橙红）。离线时不能一直显示一条过时的 AI 理由。

**(c) 语法**
- `@main struct FlowbeatApp: App`、`@StateObject`（拥有对象）+ `.environmentObject` 注入、子视图 `@EnvironmentObject` 读取。
- `TabView { ... }.tabViewStyle(.verticalPage)`：watchOS 上下翻页。
- `Circle().trim(from:to:)` + `AngularGradient` 画渐变圆环；`.contentTransition(.numericText())` 数字滚动动画；`.symbolEffect(.pulse)` SF Symbol 动画。
- `.containerBackground(..., for: .navigation)`：watchOS 10 的背景 API。
- `.task { }`：视图出现时启动异步任务，**视图消失时自动取消**。这里踩过坑：开始后 `StartView` 消失，`.task` 被取消，里面的 `Task.sleep` 立刻抛错，`-demoStopAfter` 马上就把 session 停了。后来改成不绑定视图生命周期的 `Task { }`。

---

## 第三部分：iPhone 伴侣

### 11. `FlowbeatPhone/FlowbeatPhoneApp.swift` + `FlowbeatCore/Sources/FlowbeatPhoneUI/SessionViews.swift`

**(a) 骨架**
- `SessionStore`：从 `SessionArchive` 读存档；一条都没有时显示打包进 app 的示例（明确标「示例数据：手表模拟器演示模式生成」）。
- `WatchReceiver`：`WCSessionDelegate`，`didReceive file` 时同步导入存档并刷新列表；显示配对状态。
- 列表页 `NavigationStack` + `List`，详情页 `SessionDetailContent`：
  - 汇总：平均分、时长、心流占比、离座次数。
  - `ScoreTimelineChart`（Swift Charts）：`LineMark` 画规则分曲线（按段断开），`RectangleMark` 画离座区间，`RuleMark` 画 70 分心流线和你的标签，`PointMark`（◆）画 AI 判断。
  - AI 判断列表 + AI 复盘卡片。

**(b) 为什么**
- **视图为什么放在 Swift package（`FlowbeatPhoneUI`）里？** 这台开发机没有 iOS 模拟器运行时（下载要好几 GB，超出项目范围）。视图放在 package 里就能在 macOS 上编译，用 `ImageRenderer` 渲染 README 截图（`swift run render-snapshots`）；iOS app 的真实构建和模拟器截图放在 GitHub Actions 上做。
- `List`、导航栏这类系统容器放在 iOS target 里，因为 `ImageRenderer` 渲染不了它们。
- 手表 app 的 bundle id 改成 `com.xungirl.flowbeat.watchkitapp`（必须以 iPhone app 的 id 为前缀），加 `WKCompanionAppBundleIdentifier`，并设 `WKRunsIndependentlyOfCompanionApp = YES`，没有 iPhone 也能独立用。

**(c) 语法**
- `Chart { ForEach(...) { LineMark(x: .value("分钟", m), y: .value("专注分", s), series: .value("段", seg)) } }`：`series` 让同一个 Chart 画多条不相连的线。
- `.chartYScale(domain: 0...100)`、`.chartXScale(domain:)`、`.annotation(position: .top)`。
- `NavigationStack(path:)` + `.navigationDestination(for:)`：值驱动导航。
- `WCSessionDelegate` 在 iOS 上必须实现 `sessionDidBecomeInactive` 和 `sessionDidDeactivate`（换手表时重新激活）。

---

## 第四部分：后端（backend/app/）

### 12. `schemas.py`：数据格式 + 校验

**(a) 骨架**：Pydantic 模型和 Swift 一一对应。每个字段都有物理上合理的上下限：心率 25–250、`still_ratio` 0–1、`local_time` 必须是 `HH:mm`、标注例子最多 20 条、HRV 5–250 ms。`LLMJudgment`（让模型输出的三个字段）和 `Judgment`（返回给手表，多一个 `source`）分开。

**(b) 为什么**
- 校验挡住明显坏掉或恶意的数据（返回 422），**不替模型做判断**，所以范围很宽。
- **`source` 为什么不能让模型填？** 它表示「这个结果是 LLM 给的还是兜底」，是后端的事实，模型填的话可能乱写。所以模型按 `LLMJudgment` 解析，后端再包一层。

**(c) 语法**：`Field(ge=, le=, pattern=, max_length=)`、`Literal["focused", ...]`、继承 `BaseModel`、`model_dump(exclude_none=True, exclude={...})`。

### 13. `prompts.py`：提示词

**(a) 骨架**：系统提示词固定（写明生理常识只是倾向、用户本人的标注优先、数据矛盾判 unclear、HRV 是弱参考）；user 消息里依次放：用户标注例子、本次前几个窗口的判断、当前窗口。**默认把 `rule_score_mean` 从当前窗口和例子里都去掉**；`JUDGE_INCLUDE_RULE_SCORE=1` 恢复旧行为。

**(b) 为什么**
- 系统提示词不变，变化的数据都在 user 消息里，有利于 prompt caching。
- **锚定偏差**见下面的面试题。关键发现是：模型抄的分数来自**标注例子里的规则分**，所以只从当前窗口去掉不够。

### 14. `providers.py`：LLM 提供方

**(a) 骨架**：`QwenProvider`（DashScope 的 OpenAI 兼容接口、JSON 模式、`enable_thinking=False`）、`ClaudeProvider`（结构化输出，**从没在线跑过**，没有 Anthropic key）、`FakeProvider`（按简单规则返回，测试和本地联调用）。`get_provider()` 按 `LLM_PROVIDER` 或有哪个 key 自动选。

**(b) 为什么**
- 统一的 `judge()` / `review()` 接口，换模型不改业务代码。
- **SDK 自带重试关掉了**（`max_retries=0`），重试只在 `resilience.py` 一层，否则 SDK 3 次 × 我们 2 次会叠成 6 次。
- **踩过的坑**：原来把 Pydantic 的 JSON Schema 原样塞进提示词，`qwen3.8-flash` 在 `/v1/review` 上**照抄 schema 的嵌套结构**（`{"summary": {"description": "...", "type": "string"}}`），每次都校验失败。这个 bug 之前没被发现，因为 review 从没在线测过；加上兜底后，结构化日志里出现了 `source=fallback, error=千问返回的格式不对`，才暴露出来。现在改成扁平的 `{"字段": "类型，说明"}`，在线复测 2/2 成功。

### 15. `resilience.py`：超时 + 重试 + 兜底

**(a) 骨架**：`call_with_retry(fn, settings, op)`：每次 `asyncio.wait_for` 超时 8 秒；只对超时、429、502/503/504 重试，退避 `0.5 × 2^(n−1)` 秒，默认重试 1 次；全部失败返回 `value=None`。`fallback_judgment`：离座 > 60 秒 → away；有规则分就按 ≥70 focused、<40 distracted、其他 unclear；没规则分 → unclear 50。`fallback_review` 用统计数字拼一句总结。

**(b) 为什么**
- 手表请求超时是 30 秒；单次 LLM 8 秒 + 1 次重试，最坏情况也在 30 秒内给出结果。
- **宁可给一个保守的结果，也不让手表等 30 秒后什么都拿不到**；结果带 `source="fallback"`，手表和日志都能区分。
- 401 key 无效、格式错误这类重试没用，不重试（`test_auth_error_is_not_retried`）。
- 兜底用规则分：这里用它不算「锚定」，因为此时根本没有 LLM 判断。

**(c) 语法**：`asyncio.wait_for`、`TimeoutError`（3.11+ 和 `asyncio.TimeoutError` 是同一个）、`Generic[T]` + `@dataclass`、把 `sleep` 当参数注入方便测试（`test_backoff_doubles` 断言等待序列 `[0.5, 1.0, 2.0]`）。

### 16. `config.py` / `logs.py` / `main.py`

**(a) 骨架**
- `config.Settings`：所有环境变量集中读；`FLOWBEAT_REQUIRE_TOKEN=1` 时没口令**拒绝启动**。
- `logs.JsonFormatter`：一行一个 JSON；`extra=` 传进来的字段原样输出。
- `main.py`：`lifespan` 里读配置、校验、选 provider；中间件生成或透传 `X-Request-ID`，每个请求一行日志（路径、状态码、耗时、provider、source、attempts、窗口分钟）；`check_token` 用 `secrets.compare_digest`；`/healthz` 不需要口令也不调 LLM。

**(b) 为什么**
- **配置错了就启动失败**，而不是带病运行到第一个请求才出错。Docker 镜像默认 `FLOWBEAT_REQUIRE_TOKEN=1`，部署时忘了设口令就直接起不来（CI 里验证了退出码是 3）。
- **日志不记身体数据**（测试里断言日志里没有 `hr_mean`、`still_ratio`）。
- `compare_digest` 是常数时间比较，防计时攻击。
- provider 和 settings 放在 `app.state`、通过依赖注入拿，测试里可以直接换成会超时或会失败的假 provider。

**(c) 语法**：`@asynccontextmanager` lifespan、`@app.middleware("http")`、`Depends(...)`、`Header(default=None)`、`TestClient` 要用 `with` 才会触发 lifespan。

### 17. `scripts/compare_models.py` 和 `scripts/export_contract.py`

- `compare_models.py`：同一组窗口 × 三种条件（`none` / `rule` / `misleading`）× N 轮，记录状态、分数、延迟、token；`--dry-run` 先算调用次数，`--summarize` 从保存的 JSON 重新出表、不花钱。原始数据在 `scripts/results/*.json`。
- `export_contract.py`：从 Pydantic 导出字段契约给两边测试用。

### 18. 测试、构建、CI

- Swift：`FlowbeatCore/Tests/`，XCTest，macOS `swift test` 和 watchOS 模拟器 `xcodebuild test` 跑同一套。
- Python：`backend/tests/`，全部用 Fake / Scripted provider，不调真模型。
- `project.yml`（XcodeGen）：`.xcodeproj` 不进 git，改 yml 再 `xcodegen generate`；scheme 的 test 直接引用 package 的测试 target。
- `backend/Dockerfile`：两阶段，builder 用 uv 按 `uv.lock` 装依赖，运行镜像只有 `.venv` + 代码、非 root 用户、`HEALTHCHECK` 打 `/healthz`。本机没有 Docker，所以镜像只在 CI 里构建和冒烟测试过。
- `.github/workflows/ci.yml`：后端 pytest、Docker 构建和容器冒烟（无口令启动必须失败、有口令 200）、macOS 上 `swift test`、watchOS 模拟器测试 + iPhone app 构建 + iOS 模拟器截图。

---

## 第五部分：面试题和回答

（数字的出处见 README 的 Key metrics 表。）

**Q1. 为什么要开一个 workout session 才能拿心率？不开会怎样？**
watchOS 平时大约几分钟才测一次心率，而且你放下手腕后 app 很快会被挂起。开 `HKWorkoutSession` 后，心率传感器每隔几秒连续测，`HKLiveWorkoutBuilder` 通过 delegate 回调推给你，同时 `WKBackgroundModes: workout-processing` 让 app 在后台继续运行。我选 `mindAndBody` 类型，结束时 `discardWorkout()`，不往健康数据里写假锻炼。代价是 workout 更耗电。**这些都没在真手表上验证过**：比如真机上心率到底多久来一次、一小时耗多少电，我都还不知道。

**Q2. 专注分怎么算的？为什么这样设计？**
100 减两项扣分：动作扣分最多 60（10 秒平均加速度超过 0.02g 开始扣，到 0.15g 扣满），心率扣分最多 40（高于校准基线 5 bpm 开始扣，到 +20 扣满）；然后 α=0.2 指数平滑。基线是前 60 秒心率的中位数。设计原则是透明、可测、离线：没有标注数据，没法训练模型。每个边界都有单元测试（`FocusScorerTests` 14 个）。我承认这些阈值是启发式的，没有用真实数据校准过。

**Q3. 走路的时候怎么处理？**
`CMMotionActivityManager` 说 walking/running（置信度不是 low）就进入离座：不打分、不计入专注占比、不进校准基线。坐回来后 60 秒恢复期不按心率扣分。状态机抽成 `AwayTracker`，重复事件不重复计数，有 5 个单测。

**Q4. 既然有规则分，为什么还要 LLM？LLM 为什么放在规则之上，而不是替代规则？**
规则每秒跑、离线、免费、可解释，负责实时圆环。LLM 每 2 分钟看一次统计摘要，加上你自己的标注例子，给一个**个性化的第二意见**和一句人话理由。比如「心率高但手腕静止」，规则会扣分，但对某些人这是紧张但专注。LLM 不替代规则，原因有四个：要联网、有延迟（中位数约 1.1 秒）、要花钱、输出不稳定（下面会讲到模型在模糊用例上会翻转）。所以 LLM 挂了、离线时，手表照常工作，后端还有规则分兜底。

**Q5. few-shot 个性化具体怎么做的？**
用户在手表上点「专注 / 走神」时，把最近 60 秒压成一个 `WindowSummary`，带上标签存进 `UserDefaults`（最多 20 条）。每次判断都把这些例子发给后端，放进 user 消息，系统提示词写明「相似数据优先按用户本人的标注判断」。好处是不需要训练、不需要数据库，后端无状态。代价是每多一条例子大约多 110 个输入 token（README Runs 1–2 的测量）。**局限**：还没有真实用户的标注数据，few-shot 到底有没有让判断更准，没有验证过。

**Q6. 你说发现了「锚定偏差」，具体是什么？怎么发现、怎么修、怎么验证的？**
- **发现**：2026-11-11 对比三个模型时，两个清晰用例上所有模型给的分数都恰好等于我们发过去的 `rule_score_mean`（92 / 48）。LLM 等于在复读规则分，没有独立判断。
- **修**：提示词默认不再发规则分，**当前窗口和标注例子里都去掉**；`JUDGE_INCLUDE_RULE_SCORE=1` 可以恢复。
- **验证**（Run 3，90 次真实调用）：同一个窗口用三种条件测：不发、发真实规则分、发一个故意相反的规则分。
  - 不发时，30 个分数里有 0 个等于规则分；发真实规则分时有 10/30。
  - 关键发现：在 misleading 条件下窗口里写的是 15，`focused` 用例还是给了 92。92 是**匹配的那条标注例子里存的规则分**。所以模型抄的是例子，这也是为什么必须连例子一起去掉。
  - 规则分并不是完全没用：把它换成误导值时，flash 有 4/18、max 有 6/12 对的判断结论变了。比如 flash 对 `typing` 用例，有真实规则分时判专注，没有时判走神。
- **诚实的结论**：去掉规则分让 LLM 变成真正独立的第二意见，但**独立不等于更准**。没有规则分时两个模型在 `typing` 上意见相反，在 `tense-but-still` 上也各翻转了一次。没有真实标注，不知道谁对。

**Q7. 为什么选 qwen3.8-flash？**
三轮测量里，清晰用例上各模型结论一致，差别在延迟和模糊用例。flash 中位数延迟 1.10 秒，max 1.51 秒；把规则分换成误导值时，flash 的分数几乎不跟着动（斜率 0.05，max 0.24）。这是 6 个合成窗口、每格 2–3 次的冒烟测试，不是统计评估。

**Q8. 隐私怎么保证？**
1. 只有统计摘要离开手表（均值、最小最大、趋势、静止占比、离座秒数），没有逐秒心率序列和原始加速度。
2. 原始逐秒数据只存在手表本地 `Documents/sessions/`，要同步也只通过 WatchConnectivity 发给你自己配对的 iPhone。
3. LLM 的 key 在后端，手表只有共享口令。
4. 后端无状态、不落库，日志只记元数据，测试断言日志里没有身体数据字段。
5. workout 结束时丢弃，不写进健康数据。

还能做的：真部署时用 HTTPS（现在本地是 http + `NSAllowsLocalNetworking`），以及让用户选择完全不用 LLM。

**Q9. 后端挂了 / 网络断了会怎样？**
- 手表端：每秒的分数完全本地，不受影响。判断请求进 `JudgeSync` 队列：
  - 退避 15 → 30 → 60 … 最多 300 秒，队列最多 30 条、最长 1 小时，4xx 直接丢。
  - UI 显示「AI 离线 · 排队 N 条」，结束时最后再试一次。
  - 模拟器实测：后端停 62 秒，期间 2 个窗口排队，重启后 6 秒内按顺序送达（截图在 `docs/screenshots/`）。
- 后端端：LLM 超时或出错时重试 1 次，还不行就按规则分兜底，返回 200 + `source="fallback"`。实测过：把 DashScope 地址指向不可达端口，两次 504 后返回兜底结果。

**Q10. 为什么用 actor？会有什么并发问题？**
`submit` 里 `await send()` 时 actor 可以重入，另一个 `submit` 进来也会调 `flush`，可能把队头发两次。我用 `isFlushing` 标记：已经有 flush 在跑时，新的 `submit` 只入队，由正在跑的循环把它发掉。测试里两个 `submit` 并发、每个请求延迟 30 毫秒，断言后端只收到 2 次。

**Q11. 怎么验证专注分是对的？**（重要，要诚实）
**现在没有验证。** 所有数据都来自模拟器的假传感器。我的计划是：
1. 真手表上收集带标签的 session（专注 / 走神按钮就是为这个设计的，每秒样本都存了）。
2. 把标签当 ground truth，算规则分和 LLM 判断的准确率 / F1，以及阈值 70 附近的 ROC。
3. 用这些数据调阈值，或用 Create ML 训一个个人模型，留出法评估。
4. 可选：对照外部任务指标，比如番茄钟里完成的工作量，或者自评问卷。

难点在于标签稀疏、有偏差（人通常在发现自己走神时才点），以及心率受咖啡、运动、温度影响。

**Q12. 契约测试是怎么做的？为什么需要？**
Swift 和 Python 两边各定义一遍数据结构，字段名对不上时，Swift 会悄悄不发或者 Pydantic 返回 422。所以我从 Pydantic 导出字段名到 `contract_fields.json`：Swift 测试把所有可选字段填满后编码，比较 key 集合；Python 测试比较 `model_fields`。加 HRV 字段时，就是先改 Pydantic、重新导出，两边测试一起过才算完成。

**Q13. 后端怎么防止被滥用？**
共享口令（`X-Flowbeat-Token`，常数时间比较）、镜像默认没口令不启动、请求体字段范围校验、列表长度上限（例子 20、窗口 240）、LLM 超时。还缺的：限流（比如每个口令每分钟 N 次）、HTTPS、口令轮换。现在没有部署到公网。

**Q14. 结构化日志有什么用？举个例子。**
每个请求一行 JSON，有 request_id、状态码、耗时、provider、source、attempts、error。这次就是靠它发现 review 的 bug：日志里 `/v1/review` 是 `source=fallback, attempts=2, error=千问返回的格式不对`。没有兜底，这会是一个 502；没有结构化日志，也很难一眼看出是格式问题而不是网络问题。

**Q15. 重试为什么只重试 1 次？退避多少？**
手表请求超时 30 秒，单次 LLM 超时 8 秒，1 次重试 + 0.5 秒退避，最坏情况约 16.5 秒，还有余量。重试太多会让手表等到超时，那还不如直接兜底。都可以用环境变量调。

**Q16. 为什么用 XcodeGen？为什么把逻辑放进 Swift Package？**
`.xcodeproj` 是巨大的、难以 review 的 XML，多人改容易冲突；`project.yml` 几十行，可读、可 diff。逻辑放进 Swift Package 后：
- macOS 上 `swift test` 不到 1 秒跑完，CI 不需要模拟器；
- watchOS 模拟器上用同一套测试再跑一遍；
- 手表和 iPhone 共用同一份模型和时间线逻辑。

**Q17. iPhone app 怎么拿到数据？没收到会怎样？**
手表存档后 `transferFile`，系统排队、后台送达；iPhone 在 `didReceive file` 里同步导入（先校验能解析、防路径穿越）。没收到就只显示已有的存档，或者一条标明「示例」的打包数据。**WatchConnectivity 从来没有端到端测过**：这台机器没有 iOS 模拟器运行时，也没有真机。iPhone 界面是在 CI 的 iOS 模拟器（iPhone 17 Pro）上用打包的示例数据截图的，截图里状态行显示「没有配对的 Apple Watch」，说明那里没有测到传输。

**Q18. HRV 是怎么用的？为什么只是「可选」和「弱参考」？**
- 用 `HKSampleQuery` 读最近 6 小时的 SDNN，开始时读一次，之后每 5 分钟读一次。
- 取最新的一个合理读数，连同「多少分钟前」一起放进摘要；没授权或没数据就不发。
- 为什么弱：
  - Apple Watch 只是偶尔测，读数可能是几个小时前的；
  - SDNN 个体差异很大，没有个人基线就没法说高低；
  - 授权被拒时 HealthKit 不告诉你，只返回空结果。
- 提示词里写明「只能当弱参考」。真机上能不能读到、多久一次，没测过。

**Q19. 这个项目最大的风险 / 还没验证的是什么？**
1. **从没在真手表上跑过**：心率频率、电量、后台存活、权限流程、WatchConnectivity 都是未知数。
2. 分数没和真实标注比对过（Q11）。
3. LLM 判断在模糊情况下不稳定，没有 ground truth。
4. 模型对比只有 6 个合成窗口、每格 2–3 次。
5. Claude provider 写了但没在线跑过（没有 key）。
6. 离线队列只在内存里，app 被杀会丢判断。
7. 后端没部署，没有 HTTPS 和限流。

**Q20. 如果再给你两周，你先做什么？**
第一周：
- 真机跑通：免费 Apple ID 签名装到手表，验证心率频率和电量；
- 自己带着它学习 10 个以上 session，并认真打标签；
- 测 WatchConnectivity。

第二周：
- 用这些标签算规则分和 LLM 的准确率；
- 调阈值，并把离线队列持久化到文件；
- 后端加限流，部署到一个有 HTTPS 的地方。

**Q21.（追问）你怎么知道你的单测在测对的东西，而不是在测实现？**
- 测试断言的是行为和边界：比如「一秒尖峰不应该让圆环掉出心流区」「重复的 walking 事件只算一次」「离线期间不发网络请求」「坏数据不能让整个队列进入退避」，而不是内部变量。
- 契约测试把两个代码库绑在一起。
- 端到端的行为（离线排队后按顺序送达）在模拟器里跑过，有后端日志和截图为证。
- 但单测验证不了「分数有没有意义」，这只能靠真实数据（Q11）。
