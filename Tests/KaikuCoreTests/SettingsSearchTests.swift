import XCTest
@testable import KaikuCore

final class SettingsSearchTests: XCTestCase {
    private let entries = [
        SettingsSearchEntry(target: "menuBar#shortcuts", pane: "Menu Bar & Shortcuts", group: "Global Shortcuts",
                            title: "Start or stop recording", keywords: ["hotkey", "keyboard"]),
        SettingsSearchEntry(target: "accounts#openAI", pane: "Accounts", group: "Cloud Services",
                            title: "OpenAI API key", keywords: ["gpt", "token"]),
        SettingsSearchEntry(target: "accounts#custom", pane: "Accounts", group: "On Your Network",
                            title: "Custom (OpenAI-compatible)", keywords: ["lm studio", "api key"]),
        SettingsSearchEntry(target: "transcription#language", pane: "Transcription", group: "Language",
                            title: "Default language", keywords: ["italian", "auto-detect"]),
        SettingsSearchEntry(target: "integrations#headers", pane: "Integrations", group: "Webhook",
                            title: "Headers", keywords: ["api key", "token"]),
    ]

    private func targets(_ query: String) -> [String] {
        SettingsSearch.search(query, in: entries).map(\.entry.target)
    }

    func testTitlePrefixRanksFirst() {
        XCTAssertEqual(targets("openai").first, "accounts#openAI")
        XCTAssertEqual(targets("openai key").first, "accounts#openAI")
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(targets("openai shortcut"), [])
        XCTAssertEqual(targets("default lang"), ["transcription#language"])
    }

    func testSynonymsAreReported() {
        let hits = SettingsSearch.search("hotkey", in: entries)
        XCTAssertEqual(hits.map(\.entry.target), ["menuBar#shortcuts"])
        XCTAssertEqual(hits.first?.synonym, "hotkey")
        XCTAssertNil(SettingsSearch.search("openai", in: entries).first?.synonym)
    }

    func testCaseAndAccentsAreIgnored() {
        XCTAssertEqual(targets("ITALIÄN"), ["transcription#language"])
    }

    func testGroupAndPaneMatchLast() {
        XCTAssertEqual(targets("accounts"), ["accounts#openAI", "accounts#custom"])
        XCTAssertEqual(targets("token").first, "accounts#openAI")
    }

    func testEmptyQueryFindsNothing() {
        XCTAssertEqual(targets("  "), [])
    }

    func testHighlights() {
        let text = "OpenAI API key"
        let ranges = SettingsSearch.highlights(in: text, query: "open ke")
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Open", "ke"])
    }
}
