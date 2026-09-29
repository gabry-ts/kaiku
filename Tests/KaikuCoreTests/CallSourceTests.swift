import XCTest
@testable import KaikuCore

final class CallSourceTests: XCTestCase {
    func testNativeAppsMapToTheirSource() {
        XCTAssertEqual(CallSource.resolve(bundleID: "us.zoom.xos", windowTitle: nil), "Zoom")
        XCTAssertEqual(CallSource.resolve(bundleID: "com.apple.avconferenced", windowTitle: nil), "FaceTime")
        XCTAssertEqual(CallSource.resolve(bundleID: "net.whatsapp.WhatsApp", windowTitle: "Anna"), "WhatsApp")
        XCTAssertEqual(CallSource.resolve(bundleID: "com.microsoft.teams2", windowTitle: nil), "Microsoft Teams")
    }

    func testUnknownAppsHaveNoSource() {
        XCTAssertNil(CallSource.resolve(bundleID: "com.apple.VoiceMemos", windowTitle: "Voice Memos"))
    }

    func testSameServiceInAppAndBrowserIsOneSource() {
        let app = CallSource.resolve(bundleID: "net.whatsapp.WhatsApp", windowTitle: nil)
        let web = CallSource.resolve(bundleID: "com.google.Chrome.helper", windowTitle: "(3) WhatsApp - Google Chrome")
        XCTAssertEqual(app, "WhatsApp")
        XCTAssertEqual(web, "WhatsApp")
        XCTAssertEqual(CallSource.resolve(bundleID: "com.apple.Safari", windowTitle: "Chat | Microsoft Teams"), "Microsoft Teams")
    }

    func testBrowserFallsBackToBrowserName() {
        XCTAssertEqual(CallSource.resolve(bundleID: "com.google.Chrome", windowTitle: nil), "Google Chrome")
        XCTAssertEqual(CallSource.resolve(bundleID: "com.google.Chrome", windowTitle: "  "), "Google Chrome")
        XCTAssertEqual(CallSource.resolve(bundleID: "com.apple.WebKit.GPU", windowTitle: "(2) - Safari"), "Safari")
    }

    func testBrowserTitleNormalization() {
        XCTAssertEqual(CallSource.normalizeBrowserTitle("(3) WhatsApp"), "WhatsApp")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("(12+) WhatsApp"), "WhatsApp")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Meet – abc-defg-hij – Google Chrome"), "Google Meet")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Meet - Weekly sync"), "Google Meet")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Jitsi Meet"), "Jitsi Meet")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("general - Acme - Slack"), "Slack")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Zoom Meeting"), "Zoom")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Riunione — Mozilla Firefox"), "Riunione")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Chat - Personal - Microsoft\u{200B} Edge"), "Chat")
    }

    func testUnknownTitleKeepsFirstPart() {
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Meeting notes - Google Docs - Google Chrome"), "Meeting notes")
        XCTAssertEqual(CallSource.normalizeBrowserTitle("Client X | Portal"), "Client X")
        XCTAssertNil(CallSource.normalizeBrowserTitle(""))
        XCTAssertNil(CallSource.normalizeBrowserTitle("Google Chrome"))
    }

    func testDefaultRules() {
        let rules = SourceRules()
        XCTAssertEqual(rules.rule(for: "Zoom"), .always)
        XCTAssertEqual(rules.rule(for: "Google Meet"), .always)
        XCTAssertEqual(rules.rule(for: "WhatsApp"), .new)
        XCTAssertEqual(rules.rule(for: "Telegram"), .new)
        XCTAssertEqual(rules.rule(for: "Meeting notes"), .new)
        XCTAssertEqual(rules.rule(for: "Google Chrome"), .new)
    }

    func testSavedRulesOverrideDefaultsCaseInsensitively() {
        var rules = SourceRules()
        rules.set(.never, for: "whatsapp")
        XCTAssertEqual(rules.rule(for: "WhatsApp"), .never)
        rules.set(.always, for: "WhatsApp")
        XCTAssertEqual(rules.rule(for: "whatsapp"), .always)
        XCTAssertEqual(rules.saved.count, 1)
        rules.set(.never, for: "Zoom")
        XCTAssertEqual(rules.rule(for: "zoom"), .never)
    }

    func testRulesRoundTripThroughJSON() throws {
        var rules = SourceRules()
        rules.set(.never, for: "WhatsApp")
        rules.set(.always, for: "Client X")
        let decoded = try JSONDecoder().decode(SourceRules.self, from: JSONEncoder().encode(rules))
        XCTAssertEqual(decoded, rules)
    }

    func testMigrationFromDisabledApps() {
        let rules = SourceRules.migrated(disabledAppIDs: ["zoom", "chrome", "teams", "unknown"])
        XCTAssertEqual(rules.saved, ["Zoom": .never, "Microsoft Teams": .never])
        XCTAssertEqual(rules.rule(for: "Slack"), .always)
    }
}

final class SourceCacheTests: XCTestCase {
    func testSourceIsResolvedOnceWhileActive() {
        var cache = SourceCache()
        var calls = 0
        var title = "WhatsApp"
        let resolve: (String) -> String = { _ in calls += 1; return title }
        XCTAssertEqual(cache.update(active: ["chrome"], resolve: resolve), ["chrome": "WhatsApp"])
        title = "Gmail"
        XCTAssertEqual(cache.update(active: ["chrome"], resolve: resolve), ["chrome": "WhatsApp"])
        XCTAssertEqual(calls, 1)
    }

    func testSourceIsResolvedAgainAfterTheAppStops() {
        var cache = SourceCache()
        var title = "WhatsApp"
        let resolve: (String) -> String = { _ in title }
        _ = cache.update(active: ["chrome"], resolve: resolve)
        XCTAssertEqual(cache.update(active: [], resolve: resolve), [:])
        title = "Google Meet"
        XCTAssertEqual(cache.update(active: ["chrome", "Zoom"], resolve: { $0 == "Zoom" ? "Zoom" : title }),
                       ["chrome": "Google Meet", "Zoom": "Zoom"])
    }
}
