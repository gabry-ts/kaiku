import XCTest
@testable import KaikuCore

final class DictationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: Trigger

    func testHoldStartsOnPressAndStopsOnRelease() {
        var trigger = DictationTrigger(style: .hold)
        XCTAssertEqual(trigger.press(at: t0), .start)
        XCTAssertTrue(trigger.isActive)
        // Key repeat while held changes nothing.
        XCTAssertEqual(trigger.press(at: t0.addingTimeInterval(0.5)), .none)
        XCTAssertEqual(trigger.release(at: t0.addingTimeInterval(2)), .stop)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.release(at: t0.addingTimeInterval(3)), .none)
    }

    func testToggleStartsAndStopsOnPresses() {
        var trigger = DictationTrigger(style: .toggle)
        XCTAssertEqual(trigger.press(at: t0), .start)
        XCTAssertEqual(trigger.release(at: t0.addingTimeInterval(0.1)), .none)
        XCTAssertTrue(trigger.isActive)
        XCTAssertEqual(trigger.press(at: t0.addingTimeInterval(4)), .stop)
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.press(at: t0.addingTimeInterval(5)), .start)
    }

    func testShortDictationIsCancelled() {
        var hold = DictationTrigger(style: .hold)
        _ = hold.press(at: t0)
        XCTAssertEqual(hold.release(at: t0.addingTimeInterval(0.1)), .cancel)
        var toggle = DictationTrigger(style: .toggle, minimumDuration: 1)
        _ = toggle.press(at: t0)
        XCTAssertEqual(toggle.press(at: t0.addingTimeInterval(0.5)), .cancel)
    }

    func testResetReturnsToIdle() {
        var trigger = DictationTrigger(style: .hold)
        _ = trigger.press(at: t0)
        trigger.reset()
        XCTAssertFalse(trigger.isActive)
        XCTAssertEqual(trigger.release(at: t0.addingTimeInterval(2)), .none)
        XCTAssertEqual(trigger.press(at: t0.addingTimeInterval(3)), .start)
    }

    // MARK: Modes

    func testDefaultModes() {
        XCTAssertEqual(DictationModes.defaults.map(\.name), ["Message", "Email", "Code comment"])
        XCTAssertEqual(Set(DictationModes.defaults.map(\.id)).count, 3)
        XCTAssertTrue(DictationModes.defaults.allSatisfy { !$0.prompt.isEmpty && $0.provider == nil })
    }

    func testModesRoundTripAndFallback() {
        let modes = [DictationMode(id: "a", name: "A", prompt: "p", provider: "ollama", model: "llama3"),
                     DictationMode(id: "b", name: "B", prompt: "")]
        XCTAssertEqual(DictationModes.decode(DictationModes.encode(modes)), modes)
        XCTAssertEqual(DictationModes.decode(nil), DictationModes.defaults)
        XCTAssertEqual(DictationModes.decode(Data("garbage".utf8)), DictationModes.defaults)
        XCTAssertEqual(DictationModes.decode(DictationModes.encode([])), [])
    }

    func testActiveAndNextMode() {
        let modes = DictationModes.defaults
        XCTAssertEqual(DictationModes.active(id: "email", in: modes)?.id, "email")
        XCTAssertEqual(DictationModes.active(id: "gone", in: modes)?.id, "message")
        XCTAssertNil(DictationModes.active(id: nil, in: []))
        XCTAssertEqual(DictationModes.next(after: "message", in: modes)?.id, "email")
        XCTAssertEqual(DictationModes.next(after: "code-comment", in: modes)?.id, "message")
        XCTAssertEqual(DictationModes.next(after: "gone", in: modes)?.id, "message")
        XCTAssertNil(DictationModes.next(after: "x", in: []))
    }

    func testUniqueName() {
        let modes = [DictationMode(name: "New mode", prompt: ""), DictationMode(name: "new mode 2", prompt: "")]
        XCTAssertEqual(DictationModes.uniqueName("New mode", in: modes), "New mode 3")
        XCTAssertEqual(DictationModes.uniqueName("Notes", in: modes), "Notes")
    }

    // MARK: Prompt

    func testRenderPrompt() {
        let mode = DictationMode(name: "Email", prompt: "  Be formal.  ")
        let out = DictationPrompt.render(template: DictationPrompt.defaultPrompt, text: "ciao ehm come va", mode: mode)
        XCTAssertTrue(out.contains("\nBe formal.\n"))
        XCTAssertTrue(out.hasSuffix("Text:\nciao ehm come va"))
        XCTAssertFalse(out.contains("{{"))

        let plain = DictationPrompt.render(template: DictationPrompt.defaultPrompt, text: "x", mode: nil)
        XCTAssertFalse(plain.contains("{{instructions}}"))
        XCTAssertFalse(plain.contains("Be formal"))
    }

    func testRenderPromptWithoutPlaceholders() {
        XCTAssertEqual(DictationPrompt.render(template: "Fix it.", text: "hello", mode: nil), "Fix it.\n\nText:\nhello")
        XCTAssertEqual(DictationPrompt.render(template: "  ", text: "t", mode: nil),
                       DictationPrompt.render(template: DictationPrompt.defaultPrompt, text: "t", mode: nil))
    }

    func testCleanResponse() {
        XCTAssertEqual(DictationPrompt.cleanResponse("  Hello there.\n"), "Hello there.")
        XCTAssertEqual(DictationPrompt.cleanResponse("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(DictationPrompt.cleanResponse("«Ciao.»"), "Ciao.")
        XCTAssertEqual(DictationPrompt.cleanResponse("```\nlet x = 1\n```"), "let x = 1")
        XCTAssertEqual(DictationPrompt.cleanResponse("```text\nHi\n```"), "Hi")
        // Quotes that don't wrap the whole text stay.
        XCTAssertEqual(DictationPrompt.cleanResponse("\"A\" and \"B\""), "\"A\" and \"B\"")
    }

    // MARK: Text

    func testJoin() {
        XCTAssertEqual(DictationText.join([" Hello ", "world .", "", "Again"]), "Hello world. Again")
    }

    func testRemoveFillers() {
        XCTAssertEqual(DictationText.removeFillers("Ehm, ciao come stai"), "Ciao come stai")
        XCTAssertEqual(DictationText.removeFillers("ciao, ehm, come va"), "ciao, come va")
        XCTAssertEqual(DictationText.removeFillers("Va bene uhm. poi ci sentiamo"), "Va bene. Poi ci sentiamo")
        XCTAssertEqual(DictationText.removeFillers("I think um we should go"), "I think we should go")
        XCTAssertEqual(DictationText.removeFillers("Summer is here"), "Summer is here")
        XCTAssertEqual(DictationText.removeFillers("ehm"), "")
    }

    // MARK: History

    func testHistoryKeepsNewestFirstWithLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kaiku-dictation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(url: dir.appendingPathComponent("sub/history.json"))
        XCTAssertEqual(history.load(), [])

        for i in 0..<(DictationHistory.limit + 5) {
            try history.append(DictationEntry(id: "\(i)", date: t0.addingTimeInterval(Double(i)), text: "t\(i)", mode: "Email"))
        }
        let entries = history.load()
        XCTAssertEqual(entries.count, DictationHistory.limit)
        XCTAssertEqual(entries.first?.id, "\(DictationHistory.limit + 4)")
        XCTAssertEqual(entries.first?.date, t0.addingTimeInterval(Double(DictationHistory.limit + 4)))
        XCTAssertEqual(entries.first?.mode, "Email")

        XCTAssertEqual(try history.remove(id: entries[0].id).count, DictationHistory.limit - 1)
        try history.clear()
        XCTAssertEqual(history.load(), [])
    }
}
