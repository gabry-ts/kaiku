import XCTest
@testable import KaikuCore

final class ActionDestinationsTests: XCTestCase {
    func testThingsURLEncodesTextAndAddsDeadline() throws {
        let item = ActionItem(text: "Send A&B + C", due: "2026-10-09")
        let url = try XCTUnwrap(ActionItems.thingsURL(item, notes: "Plan\n2026-10-03"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "things")
        XCTAssertEqual(components.queryItems?.first { $0.name == "title" }?.value, "Send A&B + C")
        XCTAssertEqual(components.queryItems?.first { $0.name == "notes" }?.value, "Plan\n2026-10-03")
        XCTAssertEqual(components.queryItems?.first { $0.name == "deadline" }?.value, "2026-10-09")
    }

    func testThingsURLWithoutDueHasNoDeadline() throws {
        let url = try XCTUnwrap(ActionItems.thingsURL(ActionItem(text: "x"), notes: "n"))
        XCTAssertFalse(url.absoluteString.contains("deadline"))
    }

    func testLinearIssueBody() throws {
        let item = ActionItem(text: "Fix \"it\"", due: "2026-10-09")
        let data = try ActionItems.linearIssueBody(teamID: "t1", projectID: "p1", item: item, description: "Call\n/path")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((obj["query"] as? String)?.contains("issueCreate") == true)
        let input = try XCTUnwrap((obj["variables"] as? [String: Any])?["input"] as? [String: String])
        XCTAssertEqual(input, ["teamId": "t1", "projectId": "p1", "title": "Fix \"it\"", "description": "Call\n/path", "dueDate": "2026-10-09"])
    }

    func testLinearIssueBodyWithoutProject() throws {
        let data = try ActionItems.linearIssueBody(teamID: "t1", projectID: "", item: ActionItem(text: "x"), description: "d")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try XCTUnwrap((obj["variables"] as? [String: Any])?["input"] as? [String: String])
        XCTAssertNil(input["projectId"])
        XCTAssertNil(input["dueDate"])
    }

    func testParseLinearChoices() throws {
        let teams = Data(#"{"data":{"teams":{"nodes":[{"id":"1","name":"Core"}]}}}"#.utf8)
        XCTAssertEqual(try ActionItems.parseLinearTeams(teams), [.init(id: "1", name: "Core")])
        let projects = Data(#"{"data":{"team":{"projects":{"nodes":[{"id":"9","name":"Q4"}]}}}}"#.utf8)
        XCTAssertEqual(try ActionItems.parseLinearProjects(projects), [.init(id: "9", name: "Q4")])
    }

    func testLinearErrorsAndCreateCheck() throws {
        let failure = Data(#"{"errors":[{"message":"Authentication required"}]}"#.utf8)
        XCTAssertThrowsError(try ActionItems.parseLinearTeams(failure))
        XCTAssertThrowsError(try ActionItems.checkLinearCreated(failure))
        XCTAssertNoThrow(try ActionItems.checkLinearCreated(Data(#"{"data":{"issueCreate":{"success":true}}}"#.utf8)))
        XCTAssertThrowsError(try ActionItems.checkLinearCreated(Data(#"{"data":{"issueCreate":{"success":false}}}"#.utf8)))
    }
}
