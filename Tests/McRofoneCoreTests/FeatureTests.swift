import XCTest
@testable import McRofoneCore

final class RecordingClockTests: XCTestCase {
    func testPausesAreExcluded() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var clock = RecordingClock(start: t0)
        XCTAssertEqual(clock.recordedTime(at: t0.addingTimeInterval(10)), 10)
        clock.pause(at: t0.addingTimeInterval(10))
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.recordedTime(at: t0.addingTimeInterval(25)), 10)
        clock.resume(at: t0.addingTimeInterval(30))
        XCTAssertEqual(clock.recordedTime(at: t0.addingTimeInterval(40)), 20)
        XCTAssertEqual(clock.pauses.count, 1)
        XCTAssertEqual(clock.pauses[0].offset, 10)
        // Double pause/resume are ignored.
        clock.resume(at: t0.addingTimeInterval(41))
        clock.pause(at: t0.addingTimeInterval(50))
        clock.pause(at: t0.addingTimeInterval(51))
        XCTAssertEqual(clock.pauses.count, 2)
        XCTAssertEqual(clock.pauses[1].offset, 30)
    }

    func testBookmarksInMarkdown() {
        let merged = [
            Segment(start: 0, end: 5, speaker: "Me", text: "Hello"),
            Segment(start: 10, end: 15, speaker: "Others", text: "Hi"),
        ]
        let md = TranscriptFormatter.markdown(
            header: .init(title: "T", date: Date(), durationSeconds: 20, provider: "p", language: "en", audioFiles: []),
            merged: merged,
            bookmarks: [Bookmark(time: 723, label: "Pricing"), Bookmark(time: 7, label: " ")])
        let body = md.components(separatedBy: "---\n\n").last ?? ""
        XCTAssertEqual(body.components(separatedBy: "\n\n"), [
            "**[00:00:00] Me:** Hello",
            "🔖 [00:00:07] Bookmark",
            "**[00:00:10] Others:** Hi",
            "🔖 [00:12:03] Bookmark: Pricing\n",
        ])
        // Bookmarks don't break parsing of speaker blocks.
        XCTAssertEqual(TranscriptFormatter.parseBlocks(md).count, 2)
    }
}

final class ExportTests: XCTestCase {
    let doc = ExportDocument(
        title: "Weekly <sync> & more", date: Date(timeIntervalSince1970: 0), durationSeconds: 3725,
        provider: "OpenAI (whisper-1)", language: "it",
        segments: [
            Segment(start: 3.1, end: 5.8, speaker: "Me", text: "Ciao a tutti"),
            Segment(start: 6, end: 6, speaker: "Anna", text: "Sì --> ok"),
            Segment(start: 7, end: 9, speaker: "Anna", text: "  "),
        ],
        bookmarks: [Bookmark(time: 5.9, label: "Start")])

    func testCueTime() {
        XCTAssertEqual(ExportFormatter.cueTime(3725.5, separator: ","), "01:02:05,500")
        XCTAssertEqual(ExportFormatter.cueTime(0.0004, separator: "."), "00:00:00.000")
    }

    func testSRT() {
        XCTAssertEqual(ExportFormatter.srt(doc), """
        1
        00:00:03,100 --> 00:00:05,800
        Me: Ciao a tutti

        2
        00:00:06,000 --> 00:00:07,000
        Anna: Sì --> ok

        """)
    }

    func testVTT() {
        let vtt = ExportFormatter.vtt(doc)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:03.100 --> 00:00:05.800\nMe: Ciao a tutti\n"))
        XCTAssertTrue(vtt.contains("Anna: Sì -> ok"))
    }

    func testText() {
        let txt = ExportFormatter.text(doc)
        XCTAssertTrue(txt.hasPrefix("Weekly <sync> & more\n\nDate: "))
        XCTAssertTrue(txt.contains("[00:00:03] Me: Ciao a tutti\n\n[00:00:05] Bookmark: Start\n\n[00:00:06] Anna: Sì --> ok"))
    }

    func testDocxIsValidZipWithEscapedXML() throws {
        let data = ExportFormatter.docx(doc)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(data.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06])
        let xml = ExportFormatter.documentXML(doc)
        XCTAssertTrue(xml.contains("Weekly &lt;sync&gt; &amp; more"))
        XCTAssertTrue(xml.contains("<w:b/></w:rPr><w:t xml:space=\"preserve\">Me: </w:t>"))
        // Well-formed XML.
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))

        // Round trip through the system unzip.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.docx")
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", file.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        // macOS's own .docx reader parses it.
        let out = dir.appendingPathComponent("t.txt")
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        t.arguments = ["-convert", "txt", "-output", out.path, file.path]
        try t.run()
        t.waitUntilExit()
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("Me: Ciao a tutti"), text)
        XCTAssertTrue(text.contains("Bookmark: Start"), text)
    }

    func testCRC32() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testXMLEscapeDropsControlCharacters() {
        XCTAssertEqual(ExportFormatter.xmlEscape("a\u{0001}b\"'"), "ab&quot;&apos;")
    }

    func testFileName() {
        XCTAssertEqual(ExportFormatter.fileName(title: "Sync: Q3/Q4", date: Date(timeIntervalSince1970: 86_400 * 3), format: .srt)
                        .hasSuffix("Sync- Q3-Q4.srt"), true)
    }
}

final class SilenceTrimTests: XCTestCase {
    func testDetectsLongSilencesOnly() {
        // 0.5 s windows: 2 loud, 6 silent (3 s), 2 loud, 2 silent (1 s), 2 loud.
        let loud: Float = 0.5, quiet: Float = 0.001
        let peaks = [loud, loud] + Array(repeating: quiet, count: 6) + [loud, loud, quiet, quiet, loud, loud]
        let s = SilenceTrimmer.silences(peaks: peaks, window: 0.5, options: .init(thresholdDB: -45, minDuration: 2))
        XCTAssertEqual(s, [TimeRange(start: 1, end: 4)])
    }

    func testTrailingSilence() {
        let s = SilenceTrimmer.silences(peaks: [0.5] + Array(repeating: 0, count: 5), window: 1, options: .init())
        XCTAssertEqual(s, [TimeRange(start: 1, end: 6)])
    }

    func testKeepRangesWithPadding() {
        let keep = SilenceTrimmer.keepRanges(duration: 20,
                                             silences: [TimeRange(start: 0, end: 3), TimeRange(start: 5, end: 10), TimeRange(start: 17, end: 20)],
                                             padding: 0.5)
        XCTAssertEqual(keep, [TimeRange(start: 2.5, end: 5.5), TimeRange(start: 9.5, end: 17.5)])
        // A silence shorter than twice the padding is not cut.
        XCTAssertEqual(SilenceTrimmer.keepRanges(duration: 10, silences: [TimeRange(start: 4, end: 4.8)], padding: 0.5),
                       [TimeRange(start: 0, end: 10)])
    }

    func testTimeMapRemapsSegments() {
        let map = TimeMap(keep: [TimeRange(start: 3, end: 5.5), TimeRange(start: 9.5, end: 17.5)])
        XCTAssertEqual(map.trimmedDuration, 10.5)
        XCTAssertEqual(map.toOriginal(0), 3)
        XCTAssertEqual(map.toOriginal(2), 5)
        XCTAssertEqual(map.toOriginal(2.5), 9.5)
        XCTAssertEqual(map.toOriginal(4), 11)
        XCTAssertEqual(map.toOriginal(11), 18) // past the end
        let segs = map.remap([Segment(start: 1, end: 2.5, speaker: "Me", text: "a"), Segment(start: 2.5, end: 4, text: "b")])
        XCTAssertEqual(segs[0].start, 4)
        XCTAssertEqual(segs[0].end, 5.5, accuracy: 0.01) // ends at the cut, not after it
        XCTAssertEqual(segs[1].start, 9.5)
        XCTAssertEqual(segs[1].end, 11, accuracy: 0.01)
        XCTAssertEqual(TimeMap(keep: []).toOriginal(7), 7)
    }
}

final class EstimateTests: XCTestCase {
    func testCost() {
        XCTAssertEqual(CostEstimator.estimate(seconds: 1800, pricePerHour: 0.36), 0.18)
        XCTAssertEqual(CostEstimator.pricePerHour(model: "whisper-large-v3-turbo", overrides: [:]), 0.04)
        XCTAssertEqual(CostEstimator.pricePerHour(model: "whisper-1", overrides: ["whisper-1": 0.5]), 0.5)
        XCTAssertNil(CostEstimator.pricePerHour(model: "unknown", overrides: [:]))
        XCTAssertEqual(CostEstimator.format(0.004), "<$0.01")
        XCTAssertEqual(CostEstimator.format(1.234), "$1.23")
    }

    func testCleanupSelection() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func c(_ id: String, daysAgo: Double, bytes: Int64 = 10, transcript: Bool = true, deleted: Bool = false) -> StorageCleanup.Candidate {
            .init(id: id, date: now.addingTimeInterval(-daysAgo * 86_400), audioBytes: bytes, hasTranscript: transcript, audioDeleted: deleted)
        }
        let items = [c("old", daysAgo: 40), c("new", daysAgo: 5), c("noTranscript", daysAgo: 40, transcript: false),
                     c("gone", daysAgo: 40, deleted: true), c("empty", daysAgo: 40, bytes: 0)]
        XCTAssertEqual(StorageCleanup.select(items, olderThanDays: 30, now: now).map(\.id), ["old"])
        XCTAssertEqual(StorageCleanup.select(items, olderThanDays: 0, now: now).count, 0)
    }
}

final class SummaryAPITests: XCTestCase {
    func testPrompt() {
        let p = SummaryAPI.renderPrompt(template: "Sum {{title}}:\n{{transcript}}", title: "T", transcript: "hello")
        XCTAssertEqual(p, "Sum T:\nhello")
        XCTAssertTrue(SummaryAPI.renderPrompt(template: "Just summarize", title: "T", transcript: "x").hasSuffix("Transcript:\nx"))
        XCTAssertTrue(SummaryAPI.renderPrompt(template: " ", title: "T", transcript: "x").contains("## Action items"))
    }

    func testParsers() throws {
        let chat = #"{"choices":[{"message":{"role":"assistant","content":" ## Summary\nok "}}]}"#
        XCTAssertEqual(try SummaryAPI.parseChatCompletions(Data(chat.utf8)), "## Summary\nok")
        let anthropic = #"{"content":[{"type":"text","text":"Hello"},{"type":"text","text":"World"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try SummaryAPI.parseAnthropic(Data(anthropic.utf8)), "Hello\nWorld")
        XCTAssertThrowsError(try SummaryAPI.parseAnthropic(Data(#"{"content":[]}"#.utf8)))
        let body = try JSONSerialization.jsonObject(with: SummaryAPI.anthropicBody(model: "m", prompt: "p")) as? [String: Any]
        XCTAssertEqual(body?["max_tokens"] as? Int, 4096)
    }
}

final class MeetingDetectionTests: XCTestCase {
    func testMatch() {
        XCTAssertEqual(MeetingApp.match(bundleID: "us.zoom.xos")?.id, "zoom")
        XCTAssertEqual(MeetingApp.match(bundleID: "com.google.Chrome.helper")?.id, "chrome")
        XCTAssertEqual(MeetingApp.match(bundleID: "com.microsoft.teams2")?.id, "teams")
        XCTAssertNil(MeetingApp.match(bundleID: "com.apple.Music"))
        XCTAssertEqual(MeetingApp.match(bundleID: "app.zen-browser.zen")?.id, "zen")
    }

    func testStartEndAutoStop() {
        var d = MeetingDetector(autoStopAfter: 30)
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(d.update(active: [], isRecording: false, now: t), [])
        XCTAssertEqual(d.update(active: ["zoom"], isRecording: false, now: t + 1), [.started(appID: "zoom")])
        XCTAssertEqual(d.update(active: ["zoom"], isRecording: false, now: t + 2), [])
        XCTAssertEqual(d.update(active: ["zoom"], isRecording: true, now: t + 3), [])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 10), [.ended(appID: "zoom")])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 20), [])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 41), [.autoStop])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 80), [])
    }

    func testComingBackCancelsEnd() {
        var d = MeetingDetector(autoStopAfter: 30)
        let t = Date(timeIntervalSince1970: 0)
        _ = d.update(active: ["teams"], isRecording: true, now: t)
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 1), [.ended(appID: "teams")])
        XCTAssertEqual(d.update(active: ["teams"], isRecording: true, now: t + 5), [])
        XCTAssertEqual(d.update(active: [], isRecording: true, now: t + 50), [.ended(appID: "teams")])
        // Recording without any meeting app never reports an end.
        var e = MeetingDetector()
        XCTAssertEqual(e.update(active: [], isRecording: true, now: t), [])
    }

    func testCalendarBestEvent() {
        let now = Date(timeIntervalSince1970: 10_000)
        func ev(_ title: String, _ start: Double, _ end: Double, allDay: Bool = false) -> CalendarEventInfo {
            .init(title: title, calendar: "Work", start: now + start, end: now + end, attendees: [], isAllDay: allDay)
        }
        let events = [ev("All day", -5000, 50_000, allDay: true), ev("Running", -1800, 1800), ev("Soon", 300, 2100),
                      ev("Later", 1200, 3000), ev("Past", -3600, -60)]
        XCTAssertEqual(CalendarEventInfo.best(events, now: now)?.title, "Soon")
        XCTAssertEqual(CalendarEventInfo.best([ev("Running", -1800, 1800), ev("Later", 1200, 3000)], now: now)?.title, "Running")
        XCTAssertNil(CalendarEventInfo.best([ev("Later", 1200, 3000), ev("Past", -3600, -660)], now: now))
        let withPeople = CalendarEventInfo(title: "x", calendar: nil, start: now, end: now, attendees: [
            .init(name: "Anna Rossi", email: "anna@x.com"), .init(name: nil, email: "marco@y.com"), .init(name: "Anna Rossi", email: nil),
        ])
        XCTAssertEqual(withPeople.attendeeNames, ["Anna Rossi", "marco"])
    }
}

final class TagsTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(Tags.normalize([" Nova ", "nova", "", "ACME", "  ", "Acme", "Two\nLines"]), ["Nova", "ACME", "Two Lines"])
    }

    func testRecencyAndSuggestions() {
        let d = Date(timeIntervalSince1970: 0)
        let known = Tags.byRecency([(d, ["Old", "Shared"]), (d + 100, ["Nova", "shared"]), (d + 50, ["Acme"])])
        XCTAssertEqual(known, ["Nova", "shared", "Acme", "Old"])
        XCTAssertEqual(Tags.suggestions(for: "", known: known, excluding: ["NOVA"]), ["shared", "Acme", "Old"])
        XCTAssertEqual(Tags.suggestions(for: "o", known: known, excluding: []), ["Old", "Nova"])
        XCTAssertTrue(Tags.contains(["Nova"], "nova"))
    }

    func testTagsInHeaderAndText() {
        let md = TranscriptFormatter.markdown(
            header: .init(title: "T", date: Date(), durationSeconds: 1, provider: "p", language: "en", audioFiles: [], tags: ["Nova", "Acme"]),
            merged: [])
        XCTAssertTrue(md.contains("- **Tags:** Nova, Acme"))
        let doc = ExportDocument(title: "T", date: Date(), durationSeconds: 1, provider: "p", language: "en", segments: [], tags: ["Nova"])
        XCTAssertTrue(ExportFormatter.text(doc).contains("Tags: Nova"))
        XCTAssertTrue(ExportFormatter.documentXML(doc).contains("Tags: "))
    }
}

final class EchoFilterTests: XCTestCase {
    let speakers = [OutputRoute(start: 0, end: 100, deviceName: "MacBook Pro Speakers", isHeadphones: false),
                    OutputRoute(start: 100, deviceName: "AirPods", isHeadphones: true)]

    private func dropped(_ segs: [Segment]) -> [Bool] {
        EchoFilter.markEchoes(segs, meLabel: "Me", routes: speakers).map { $0.droppedAsEcho == true }
    }

    func testTrueDuplicateIsDropped() {
        XCTAssertEqual(dropped([
            Segment(start: 10.4, end: 13, speaker: "Me", text: "Can you share the budget for next quarter?"),
            Segment(start: 10.1, end: 12.8, speaker: "Others", text: "Can you share the budget for next quarter"),
        ]), [true, false])
    }

    func testPartialOverlapWithLongerSegment() {
        XCTAssertEqual(dropped([
            Segment(start: 20, end: 23, speaker: "Me", text: "we moved billing to November"),
            Segment(start: 15, end: 30, speaker: "Speaker 1", text: "So as we said, we moved billing to November, and the library ships first."),
        ]), [true, false])
    }

    func testDifferentSpeechIsKept() {
        XCTAssertEqual(dropped([
            Segment(start: 10, end: 13, speaker: "Me", text: "I think the budget is fine as it is"),
            Segment(start: 10.5, end: 13, speaker: "Others", text: "Can you share the budget for next quarter"),
            Segment(start: 40, end: 41, speaker: "Me", text: "Yes"),
            Segment(start: 44, end: 45, speaker: "Others", text: "Yes"),
        ]), [false, false, false, false])
    }

    func testShortExactEchoAndHeadphonesUntouched() {
        XCTAssertEqual(dropped([
            Segment(start: 50, end: 51, speaker: "Me", text: "Okay, thanks!"),
            Segment(start: 50.3, end: 51, speaker: "Others", text: "okay thanks"),
            Segment(start: 110, end: 113, speaker: "Me", text: "Can you share the budget for next quarter"),
            Segment(start: 110, end: 113, speaker: "Others", text: "Can you share the budget for next quarter"),
        ]), [true, false, false, false])
        // No speaker route: nothing changes.
        let segs = [Segment(start: 1, end: 2, speaker: "Me", text: "same words here"),
                    Segment(start: 1, end: 2, speaker: "Others", text: "same words here")]
        XCTAssertEqual(EchoFilter.markEchoes(segs, meLabel: "Me", routes: [speakers[1]]), segs)
    }
}

final class MicMuteTests: XCTestCase {
    func testMethodChoice() {
        XCTAssertEqual(MutePlanner.method(.init(muteSettable: true, masterVolumeSettable: true, channelVolumeSettable: [1])), .mute)
        XCTAssertEqual(MutePlanner.method(.init(muteSettable: false, masterVolumeSettable: true, channelVolumeSettable: [1, 2])), .volume(elements: [0]))
        XCTAssertEqual(MutePlanner.method(.init(muteSettable: false, masterVolumeSettable: false, channelVolumeSettable: [2, 1])), .volume(elements: [1, 2]))
        XCTAssertEqual(MutePlanner.method(.init(muteSettable: false, masterVolumeSettable: false, channelVolumeSettable: [])), .unsupported)
    }

    func testReapplyWhenRaised() {
        XCTAssertFalse(MutePlanner.needsReapply(.mute, mute: 1, volumes: [:]))
        XCTAssertTrue(MutePlanner.needsReapply(.mute, mute: 0, volumes: [:]))
        XCTAssertFalse(MutePlanner.needsReapply(.volume(elements: [1, 2]), mute: nil, volumes: [1: 0, 2: 0]))
        XCTAssertTrue(MutePlanner.needsReapply(.volume(elements: [1, 2]), mute: nil, volumes: [1: 0, 2: 0.6]))
        XCTAssertFalse(MutePlanner.needsReapply(.unsupported, mute: 0, volumes: [0: 1]))
    }

    func testSavedStateAndMerge() throws {
        let a = MutePlanner.stateToSave(uid: "a", name: "Built-in",
                                        caps: .init(muteSettable: true, masterVolumeSettable: true, channelVolumeSettable: []),
                                        mute: 0, volumes: [0: 0.7])
        XCTAssertEqual(a, MicDeviceState(uid: "a", name: "Built-in", mute: 0, volumes: ["0": 0.7]))
        let b = MutePlanner.stateToSave(uid: "b", name: "USB",
                                        caps: .init(muteSettable: false, masterVolumeSettable: false, channelVolumeSettable: [1, 2]),
                                        mute: nil, volumes: [1: 0.5, 2: 0.8, 0: 1])
        XCTAssertEqual(b, MicDeviceState(uid: "b", name: "USB", mute: nil, volumes: ["1": 0.5, "2": 0.8]))
        XCTAssertEqual(MutePlanner.fallback(.init(muteSettable: true, masterVolumeSettable: true, channelVolumeSettable: [])), .volume(elements: [0]))
        XCTAssertEqual(MutePlanner.fallback(.init(muteSettable: true, masterVolumeSettable: false, channelVolumeSettable: [])), .unsupported)
        // A device muted again later must keep its original saved state.
        let later = MicDeviceState(uid: "b", name: "USB", mute: nil, volumes: ["1": 0, "2": 0])
        let merged = MutePlanner.merge([a, b], adding: [later, MicDeviceState(uid: "c", name: "C", mute: 1, volumes: [:])])
        XCTAssertEqual(merged.map(\.uid), ["a", "b", "c"])
        XCTAssertEqual(merged[1].volumes, ["1": 0.5, "2": 0.8])
        let data = try JSONEncoder().encode(merged)
        XCTAssertEqual(try JSONDecoder().decode([MicDeviceState].self, from: data), merged)
    }
}
