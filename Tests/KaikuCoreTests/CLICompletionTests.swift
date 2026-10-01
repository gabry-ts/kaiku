import XCTest
@testable import KaikuCore

final class CLICompletionTests: XCTestCase {
    func testClaudeArgumentsReadStdinWithoutTools() {
        let args = CLITool.claude.arguments(model: "", workDir: "/tmp/w", outputFile: "/tmp/w/last.txt")
        XCTAssertEqual(Array(args.prefix(3)), ["-p", "--output-format", "text"])
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(args[args.firstIndex(of: "--system-prompt")! + 1], CLITool.systemPrompt)
        XCTAssertFalse(args.contains("--model"))
        let withModel = CLITool.claude.arguments(model: " sonnet ", workDir: "/tmp/w", outputFile: "")
        XCTAssertEqual(Array(withModel.suffix(2)), ["--model", "sonnet"])
    }

    func testCodexArgumentsAreReadOnlyAndEndWithStdin() {
        let args = CLITool.codex.arguments(model: "", workDir: "/tmp/w", outputFile: "/tmp/w/last.txt")
        XCTAssertEqual(args.first, "exec")
        XCTAssertEqual(args.last, "-")
        XCTAssertEqual(args[args.firstIndex(of: "-s")! + 1], "read-only")
        XCTAssertEqual(args[args.firstIndex(of: "-C")! + 1], "/tmp/w")
        XCTAssertEqual(args[args.firstIndex(of: "-o")! + 1], "/tmp/w/last.txt")
        XCTAssertFalse(args.contains("-m"))
        let withModel = CLITool.codex.arguments(model: "m1", workDir: "/tmp/w", outputFile: "o")
        XCTAssertEqual(Array(withModel.suffix(3)), ["-m", "m1", "-"])
    }

    func testOpenCodeArguments() {
        XCTAssertEqual(CLITool.opencode.arguments(model: "", workDir: "/tmp/w", outputFile: ""),
                       ["run", "--pure", "--dir", "/tmp/w"])
        XCTAssertEqual(CLITool.opencode.arguments(model: "opencode/big-pickle", workDir: "/tmp/w", outputFile: "").suffix(2),
                       ["-m", "opencode/big-pickle"])
    }

    func testCandidatePathsIncludeHomeAndNodeVersions() {
        let paths = CLITool.claude.candidatePaths(home: "/Users/a", nodeVersions: ["v22.1.0"])
        XCTAssertEqual(paths.first, "/Users/a/.local/bin/claude")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/claude"))
        XCTAssertEqual(paths.last, "/Users/a/.nvm/versions/node/v22.1.0/bin/claude")
        XCTAssertEqual(CLITool.codex.loginShellArguments, ["-lc", "command -v codex"])
    }

    func testPathFromShellOutputSkipsNoise() {
        XCTAssertEqual(CLITool.path(fromShellOutput: "Welcome!\n/opt/homebrew/bin/codex\n"), "/opt/homebrew/bin/codex")
        XCTAssertNil(CLITool.path(fromShellOutput: "codex not found\n"))
    }

    func testOpenCodeModelsKeepProviderModelLines() {
        let out = "\u{1B}[0mopencode/big-pickle\nanthropic/claude-x\n\nSome notice here\n"
        XCTAssertEqual(CLITool.parseOpenCodeModels(out), ["opencode/big-pickle", "anthropic/claude-x"])
        XCTAssertEqual(CLITool.claude.modelSuggestions, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertTrue(CLITool.codex.modelSuggestions.isEmpty)
    }

    func testOpenRouterModelIDs() throws {
        let json = #"{"data":[{"id":"b/two","name":"Two"},{"id":"a/one","context_length":1}]}"#
        XCTAssertEqual(try SummaryAPI.parseModelIDs(Data(json.utf8)), ["a/one", "b/two"])
        XCTAssertThrowsError(try SummaryAPI.parseModelIDs(Data("{}".utf8)))
    }

    func testParseOutputPrefersLastMessageAndStripsColors() throws {
        XCTAssertEqual(try CLITool.parseOutput(stdout: "noise", lastMessage: " final \n"), "final")
        XCTAssertEqual(try CLITool.parseOutput(stdout: "\u{1B}[0m\u{1B}[91m\u{1B}[1mpong\u{1B}[0m\n", lastMessage: ""), "pong")
        XCTAssertThrowsError(try CLITool.parseOutput(stdout: "\u{1B}[0m\n "))
    }
}
