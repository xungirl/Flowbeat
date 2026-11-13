// swift-tools-version:5.9
// Flowbeat 的纯逻辑（打分、离座状态机、窗口摘要、离线队列、HRV 摘要）。
// 不依赖 HealthKit / CoreMotion / UI，所以能在 macOS 上 `swift test`，
// 也能在 watchOS 模拟器上 `xcodebuild test`。手表 app 和 iPhone app 都依赖它。
import PackageDescription

let package = Package(
    name: "FlowbeatCore",
    platforms: [.watchOS(.v10), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlowbeatCore", targets: ["FlowbeatCore"]),
    ],
    targets: [
        .target(name: "FlowbeatCore"),
        .testTarget(
            name: "FlowbeatCoreTests",
            dependencies: ["FlowbeatCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
