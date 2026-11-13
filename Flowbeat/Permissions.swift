import Foundation
import HealthKit
import CoreMotion
import FlowbeatCore

/// 读 / 请求 HealthKit 和「运动与健身」权限，换算成 FlowbeatCore 的 PermissionStatus。
/// 只在用户看完说明、点了「继续」之后才请求（OnboardingView），开始页根据结果显示提示。
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var health: PermissionStatus = .notDetermined
    @Published private(set) var motion: PermissionStatus = .notDetermined

    private let healthStore = HKHealthStore()
    private let activityManager = CMMotionActivityManager()

    var readiness: StartReadiness { StartReadiness.evaluate(health: health, motion: motion) }

    init() { refresh() }

    /// 只读状态，不弹窗
    func refresh() {
        #if targetEnvironment(simulator)
        // 演示模式（-demo）用模拟传感器，不需要任何权限
        // -demoDenied：模拟两个权限都被拒，用来截「被拒绝时的提示」
        if ProcessInfo.processInfo.arguments.contains("-demoDenied") {
            health = .denied
            motion = .denied
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            health = .granted
            motion = .granted
            return
        }
        #endif
        if !HKHealthStore.isHealthDataAvailable() {
            health = .unavailable
        } else {
            // 读权限的状态 HealthKit 不告诉 app（隐私设计），能查的是「写体能训练」——开 workout 必需
            switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
            case .sharingAuthorized: health = .granted
            case .sharingDenied: health = .denied
            default: health = .notDetermined
            }
        }
        if !CMMotionActivityManager.isActivityAvailable() {
            motion = .unavailable
        } else {
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: motion = .granted
            case .denied, .restricted: motion = .denied
            default: motion = .notDetermined
            }
        }
    }

    /// 弹系统授权窗：先「健康」（心率 + 体能训练），再「运动与健身」。已经回答过的不会再弹。
    func requestAll(includeHRV: Bool) async {
        if HKHealthStore.isHealthDataAvailable() {
            var read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
            if includeHRV { read.insert(HKQuantityType(.heartRateVariabilitySDNN)) }
            try? await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: read)
        }
        if CMMotionActivityManager.isActivityAvailable(),
           CMMotionActivityManager.authorizationStatus() == .notDetermined {
            // CoreMotion 没有单独的「请求授权」API：第一次查询活动记录时系统弹窗
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let now = Date()
                activityManager.queryActivityStarting(from: now.addingTimeInterval(-60), to: now, to: .main) { _, _ in
                    done.resume()
                }
            }
        }
        refresh()
    }
}
