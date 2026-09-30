import XCTest
@testable import KaikuCore

final class NotificationTests: XCTestCase {
    func testEveryKindIsOnWithSoundByDefault() {
        XCTAssertEqual(NotificationKind.allCases.count, 10)
        XCTAssertTrue(NotificationKind.allCases.allSatisfy { $0.defaultShown() })
        XCTAssertTrue(NotificationKind.allCases.allSatisfy(\.defaultSound))
    }

    func testKeysAreStableAndUnique() {
        XCTAssertEqual(NotificationKind.callEnded.showKey, "notify.callEnded.show")
        XCTAssertEqual(NotificationKind.callEnded.soundKey, "notify.callEnded.sound")
        let keys = NotificationKind.allCases.flatMap { [$0.showKey, $0.soundKey] }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testTitlesAndDetailsAreFilledAndUnique() {
        let titles = NotificationKind.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertTrue(NotificationKind.allCases.allSatisfy { !$0.title.isEmpty && $0.detail.hasSuffix(".") })
    }

    func testOldTranscriptSwitchCarriesOverToInformationalKinds() {
        let informational: Set<NotificationKind> = [.recordingStarted, .recordingStopped, .transcriptReady, .problem, .cleanup]
        for kind in NotificationKind.allCases {
            XCTAssertEqual(kind.defaultShown(legacyInformational: false), !informational.contains(kind), kind.rawValue)
            XCTAssertTrue(kind.defaultShown(legacyInformational: true), kind.rawValue)
        }
    }

    func testOldAskToStopSwitchCarriesOverToCallEnded() {
        for kind in NotificationKind.allCases {
            XCTAssertEqual(kind.defaultShown(legacyCallEnded: false), kind != .callEnded, kind.rawValue)
        }
        XCTAssertTrue(NotificationKind.callEnded.defaultShown(legacyInformational: false, legacyCallEnded: true))
    }

    func testQuestions() {
        XCTAssertEqual(NotificationKind.allCases.filter(\.asksQuestion), [.callDetected, .newSource, .callEnded, .recovered])
    }
}
