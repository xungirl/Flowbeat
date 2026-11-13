import XCTest
@testable import FlowbeatCore

final class MemoryStore: IntegerStore {
    var values: [String: Int] = [:]
    func integer(forKey key: String) -> Int { values[key] ?? 0 }
    func set(_ value: Int, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

final class OnboardingStateTests: XCTestCase {
    func testFirstLaunchNeedsOnboarding() {
        XCTAssertTrue(OnboardingState(store: MemoryStore()).needsOnboarding)
    }

    func testCompletingHidesItOnNextLaunch() {
        let store = MemoryStore()
        OnboardingState(store: store).complete()
        XCTAssertFalse(OnboardingState(store: store).needsOnboarding, "a new instance (= next launch) reads it back")
    }

    func testANewerVersionShowsItAgain() {
        let store = MemoryStore()
        OnboardingState(store: store, version: 1).complete()
        XCTAssertTrue(OnboardingState(store: store, version: 2).needsOnboarding)
    }

    func testResetShowsItAgain() {
        let store = MemoryStore()
        let s = OnboardingState(store: store)
        s.complete()
        s.reset()
        XCTAssertTrue(s.needsOnboarding)
    }

    func testWorksWithRealUserDefaults() throws {
        let suite = "fb-onboarding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = OnboardingState(store: defaults)
        XCTAssertTrue(s.needsOnboarding)
        s.complete()
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.key), OnboardingState.currentVersion)
        XCTAssertFalse(s.needsOnboarding)
    }
}

final class StartReadinessTests: XCTestCase {
    func testAllGrantedCanStartWithNoNotices() {
        XCTAssertEqual(StartReadiness.evaluate(health: .granted, motion: .granted),
                       StartReadiness(canStart: true, notices: []))
    }

    func testHealthDeniedBlocksStartWithGuidance() {
        let r = StartReadiness.evaluate(health: .denied, motion: .granted)
        XCTAssertFalse(r.canStart)
        XCTAssertEqual(r.notices, [.healthDenied])
    }

    func testHealthNotAskedYetStillLetsYouStart() {
        let r = StartReadiness.evaluate(health: .notDetermined, motion: .notDetermined)
        XCTAssertTrue(r.canStart, "start requests authorization; never a dead end")
        XCTAssertEqual(r.notices, [.healthNotAsked])
    }

    func testMotionDeniedIsOnlyAWarning() {
        let r = StartReadiness.evaluate(health: .granted, motion: .denied)
        XCTAssertTrue(r.canStart)
        XCTAssertEqual(r.notices, [.motionDenied])
    }

    func testNoHealthKitOnDevice() {
        let r = StartReadiness.evaluate(health: .unavailable, motion: .unavailable)
        XCTAssertFalse(r.canStart)
        XCTAssertEqual(r.notices, [.healthUnavailable])
    }

    func testBothDeniedShowsBothNotices() {
        XCTAssertEqual(StartReadiness.evaluate(health: .denied, motion: .denied).notices, [.healthDenied, .motionDenied])
    }
}
