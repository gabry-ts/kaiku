import XCTest
@testable import KaikuCore

final class AudioImportTests: XCTestCase {
    func testAudioAndVideoFilesAreSupported() {
        for name in ["a.mp3", "a.m4a", "a.wav", "a.aiff", "a.caf", "a.flac", "a.mp4", "a.mov", "a.m4v", "A.MP3"] {
            XCTAssertTrue(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    func testOtherFilesAreNotSupported() {
        for name in ["a.txt", "a.pdf", "a.png", "noext", "a.md"] {
            XCTAssertFalse(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertFalse(AudioImport.isSupported(URL(fileURLWithPath: "/tmp/folder.mp3", isDirectory: true)))
    }

    func testSplitKeepsOrderAndDropsDuplicates() {
        let a = URL(fileURLWithPath: "/tmp/a.mp3"), b = URL(fileURLWithPath: "/tmp/b.txt"), c = URL(fileURLWithPath: "/tmp/c.mov")
        let r = AudioImport.split([c, b, a, c, URL(fileURLWithPath: "/tmp/./a.mp3")])
        XCTAssertEqual(r.supported, [c, a])
        XCTAssertEqual(r.unsupported, [b])
    }

    func testTitleIsTheFileNameWithoutExtension() {
        XCTAssertEqual(AudioImport.title(for: URL(fileURLWithPath: "/tmp/Weekly sync.mp3")), "Weekly sync")
        XCTAssertEqual(AudioImport.title(for: URL(fileURLWithPath: "/tmp/interview.final.m4a")), "interview.final")
        XCTAssertEqual(AudioImport.title(for: URL(fileURLWithPath: "/tmp/noext")), "noext")
        XCTAssertEqual(AudioImport.title(for: URL(fileURLWithPath: "/tmp/ .mp3")), "Imported audio")
    }

    func testDateFallsBackToNow() {
        let created = Date(timeIntervalSince1970: 1_000), now = Date(timeIntervalSince1970: 5_000)
        XCTAssertEqual(AudioImport.date(created: created, now: now), created)
        XCTAssertEqual(AudioImport.date(created: nil, now: now), now)
    }

    func testProgress() {
        XCTAssertEqual(AudioImport.progress(current: 1, total: 1), "Importing…")
        XCTAssertEqual(AudioImport.progress(current: 2, total: 5), "Importing 2 of 5…")
    }

    func testImportedSourceName() {
        XCTAssertEqual(CallSource.imported, "Imported")
    }
}
