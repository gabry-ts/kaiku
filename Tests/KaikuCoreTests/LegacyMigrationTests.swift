import XCTest
@testable import KaikuCore

final class LegacyMigrationTests: XCTestCase {
    let home = "/Users/me"
    let moves = [
        PathMove(from: "/Users/me/Documents/mc.Rofone", to: "/Users/me/Documents/Kaiku"),
        PathMove(from: "/Users/me/Library/Application Support/mc.Rofone", to: "/Users/me/Library/Application Support/Kaiku"),
    ]

    func testFolderAction() {
        XCTAssertEqual(LegacyMigration.folderAction(oldExists: true, newExists: false), .move)
        XCTAssertEqual(LegacyMigration.folderAction(oldExists: true, newExists: true), .keepOld)
        XCTAssertEqual(LegacyMigration.folderAction(oldExists: false, newExists: false), .none)
        XCTAssertEqual(LegacyMigration.folderAction(oldExists: false, newExists: true), .none)
    }

    func testRewriteInsideMovedFolders() {
        XCTAssertEqual(LegacyMigration.rewrite("/Users/me/Documents/mc.Rofone", moves: moves, home: home),
                       "/Users/me/Documents/Kaiku")
        XCTAssertEqual(LegacyMigration.rewrite("/Users/me/Documents/mc.Rofone/", moves: moves, home: home),
                       "/Users/me/Documents/Kaiku")
        XCTAssertEqual(LegacyMigration.rewrite("/Users/me/Documents/mc.Rofone/2026-09-23_1430_sync", moves: moves, home: home),
                       "/Users/me/Documents/Kaiku/2026-09-23_1430_sync")
        XCTAssertEqual(LegacyMigration.rewrite("/Users/me/Library/Application Support/mc.Rofone/models/ggml-base.bin",
                                               moves: moves, home: home),
                       "/Users/me/Library/Application Support/Kaiku/models/ggml-base.bin")
    }

    func testRewriteKeepsTilde() {
        XCTAssertEqual(LegacyMigration.rewrite("~/Documents/mc.Rofone/call", moves: moves, home: home), "~/Documents/Kaiku/call")
    }

    func testRewriteLeavesOtherPaths() {
        XCTAssertNil(LegacyMigration.rewrite("/Users/me/Documents/mc.Rofone2/call", moves: moves, home: home))
        XCTAssertNil(LegacyMigration.rewrite("/Users/me/Music/calls", moves: moves, home: home))
        XCTAssertNil(LegacyMigration.rewrite("", moves: moves, home: home))
        XCTAssertNil(LegacyMigration.rewrite("/Users/me/Documents/mc.Rofone", moves: [], home: home))
    }

    func testIsSame() {
        XCTAssertTrue(LegacyMigration.isSame("~/Documents/mc.Rofone/", as: "/Users/me/Documents/mc.Rofone", home: home))
        XCTAssertFalse(LegacyMigration.isSame("/Users/me/Calls", as: "/Users/me/Documents/mc.Rofone", home: home))
    }

    func testRewrittenValues() {
        let values: [String: Any] = [
            "baseFolder": "/Users/me/Documents/mc.Rofone",
            "whisperModel": "/Users/me/Library/Application Support/mc.Rofone/models/ggml-large-v3-turbo.bin",
            "language": "auto",
            "count": 3,
            "list": ["/Users/me/Documents/mc.Rofone/a", "other"],
            "untouched": ["x", "y"],
        ]
        let out = LegacyMigration.rewrittenValues(values, moves: moves, home: home)
        XCTAssertEqual(Set(out.keys), ["baseFolder", "whisperModel", "list"])
        XCTAssertEqual(out["baseFolder"] as? String, "/Users/me/Documents/Kaiku")
        XCTAssertEqual(out["whisperModel"] as? String,
                       "/Users/me/Library/Application Support/Kaiku/models/ggml-large-v3-turbo.bin")
        XCTAssertEqual(out["list"] as? [String], ["/Users/me/Documents/Kaiku/a", "other"])
    }
}
