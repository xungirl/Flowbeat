// swift-tools-version:5.9
// Flowbeat 的纯逻辑（打分、离座状态机、窗口摘要、离线队列、HRV 摘要）。
// FlowbeatCore 不依赖 HealthKit / CoreMotion / UI，所以能在 macOS 上 `swift test`，
// 也能在 watchOS 模拟器上 `xcodebuild test`。手表 app 和 iPhone app 都依赖它。
import PackageDescription

let package = Package(
    name: "FlowbeatCore",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlowbeatCore", targets: ["FlowbeatCore"]),
        // iPhone 端的 SwiftUI + Swift Charts 视图。放在 package 里而不是 iOS target 里，
        // 这样在 macOS 上也能编译、用 ImageRenderer 渲染截图（这台机器没有装 iOS 模拟器运行时）。
        .library(name: "FlowbeatPhoneUI", targets: ["FlowbeatPhoneUI"]),
    ],
    targets: [
        .target(name: "FlowbeatCore"),
        .target(name: "FlowbeatPhoneUI", dependencies: ["FlowbeatCore"]),
        // swift run render-snapshots <session.json> <输出目录>：把 iPhone 视图渲染成 PNG
        .executableTarget(name: "render-snapshots", dependencies: ["FlowbeatCore", "FlowbeatPhoneUI"]),
        .testTarget(
            name: "FlowbeatCoreTests",
            dependencies: ["FlowbeatCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
