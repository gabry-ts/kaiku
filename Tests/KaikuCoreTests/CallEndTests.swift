import XCTest
@testable import KaikuCore

final class CallEndTests: XCTestCase {
    func testSavedMode() {
        XCTAssertEqual(CallEndMode(saved: nil), .stopAfterDelay)
        XCTAssertEqual(CallEndMode(saved: ""), .stopAfterDelay)
        XCTAssertEqual(CallEndMode(saved: "later"), .stopAfterDelay)
        XCTAssertEqual(CallEndMode(saved: "ask"), .ask)
        XCTAssertEqual(CallEndMode(saved: "nothing"), .nothing)
        XCTAssertEqual(CallEndMode.allCases.map(\.rawValue), ["stopAfterDelay", "ask", "nothing"])
    }

    func testStopAfterDelayAndNothingDoNotDependOnNotifications() {
        for allowed in [true, false] {
            for enabled in [true, false] {
                XCTAssertEqual(CallEndMode.stopAfterDelay.behavior(notificationsAllowed: allowed, callEndedNotificationEnabled: enabled), .stopAfterDelay)
                XCTAssertEqual(CallEndMode.nothing.behavior(notificationsAllowed: allowed, callEndedNotificationEnabled: enabled), .nothing)
            }
        }
    }

    func testAskNeedsTheNotification() {
        XCTAssertEqual(CallEndMode.ask.behavior(notificationsAllowed: true, callEndedNotificationEnabled: true), .ask)
        XCTAssertEqual(CallEndMode.ask.behavior(notificationsAllowed: false, callEndedNotificationEnabled: true), .stopAfterDelay)
        XCTAssertEqual(CallEndMode.ask.behavior(notificationsAllowed: true, callEndedNotificationEnabled: false), .stopAfterDelay)
        XCTAssertEqual(CallEndMode.ask.behavior(notificationsAllowed: false, callEndedNotificationEnabled: false), .stopAfterDelay)
    }

    func testOnlyTheDelayStopsByItself() {
        XCTAssertEqual(CallEndBehavior.stopAfterDelay.autoStopSeconds(delay: 60), 60)
        XCTAssertEqual(CallEndBehavior.stopAfterDelay.autoStopSeconds(delay: 0), 0)
        XCTAssertEqual(CallEndBehavior.stopAfterDelay.autoStopSeconds(delay: -5), 0)
        XCTAssertEqual(CallEndBehavior.ask.autoStopSeconds(delay: 60), 0)
        XCTAssertEqual(CallEndBehavior.nothing.autoStopSeconds(delay: 60), 0)
    }

    func testNothingIsSilent() {
        XCTAssertTrue(CallEndBehavior.stopAfterDelay.notifies)
        XCTAssertTrue(CallEndBehavior.ask.notifies)
        XCTAssertFalse(CallEndBehavior.nothing.notifies)
    }

    func testAskNeverStopsTheDetector() {
        var d = MeetingDetector(autoStopAfter: Double(CallEndBehavior.ask.autoStopSeconds(delay: 30)))
        let t = Date(timeIntervalSince1970: 0)
        _ = d.update(active: ["zoom"], isRecording: true, now: t)
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 1), [.ended(appID: "zoom")])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 3600), [])
    }
}
