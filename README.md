# FocusWatch

Apple Watch 专注监测：用 **心率 + 手腕动作** 估计你是否在专注，输出 0–100 的「专注指数」。

## 运行

```bash
brew install xcodegen      # 只需一次
xcodegen generate          # 由 project.yml 生成 FocusWatch.xcodeproj（不进 git）
open FocusWatch.xcodeproj
```

Xcode 里：
1. 选 target `FocusWatch` → **Signing & Capabilities** → Team 选你的 Apple ID（免费账号即可）
2. 手表：设置 → 隐私与安全 → **开发者模式** 打开（iPhone 上也要打开）
3. 顶部设备选你的 Apple Watch → ⌘R
4. 免费账号签名 7 天过期，过期了重新 ⌘R 一次

## 原理

| 文件 | 作用 |
|---|---|
| `FocusSession.swift` | 开 `HKWorkoutSession`（mindAndBody）拿每隔几秒一次的心率，并且能在后台继续运行；用 CoreMotion 以 25Hz 读手腕加速度；每秒算一次分，结束时丢弃这次 workout（不会往「健康」里写数据） |
| `FocusScorer.swift` | 纯逻辑：前 60 秒校准出心率基线 → 动作扣分（最多 60）+ 心率高于基线扣分（最多 40）→ 平滑 |
| `ContentView.swift` | 开始 / 进行中 / 总结 三个页面 |

每次的记录存在手表 app 的 `Documents/sessions/*.json`，进行中点「专注 / 走神」会打上标签，后面用来训练你自己的模型。

## 路线图

- [x] v0：手表端实时分数 + 校准 + 打标签 + JSON 记录
- [ ] iPhone 伴侣 app：同步记录（WatchConnectivity），画专注曲线
- [ ] 用打过的标签调阈值 / 训练个人模型（Create ML）
- [ ] 读系统 HRV（SDNN）当辅助指标
- [ ] 和 [Nod](https://github.com/xungirl/Nod) 联动：专注时压住通知

> 注意：这是基于身体信号的**估计**，不是医学测量。
