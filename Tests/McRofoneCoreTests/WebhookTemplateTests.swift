import XCTest
@testable import McRofoneCore

final class WebhookTemplateTests: XCTestCase {
    let values: [String: WebhookTemplate.Value] = [
        "title": .string("Call \"Q3\" / plan"),
        "transcript_markdown": .string("# Call\n\n**[00:00:01] Me:** Ciao\tè\\ok"),
        "duration_seconds": .raw("65"),
        "segments_json": .raw(#"[{"speaker":"Me","text":"Ciao"}]"#),
    ]

    func testJSONTemplateStaysValid() throws {
        let template = """
        {"title": "{{title}}", "text": "{{ transcript_markdown }}", "duration": {{duration_seconds}}, "segments": {{segments_json}}}
        """
        let body = WebhookTemplate.render(template, values: values, jsonEscape: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(obj["title"] as? String, "Call \"Q3\" / plan")
        XCTAssertEqual(obj["text"] as? String, "# Call\n\n**[00:00:01] Me:** Ciao\tè\\ok")
        XCTAssertEqual(obj["duration"] as? Int, 65)
        XCTAssertEqual((obj["segments"] as? [[String: String]])?.first?["speaker"], "Me")
    }

    func testPlainTextNoEscapingAndUnknownPlaceholders() {
        let body = WebhookTemplate.render("T={{title}} X={{unknown}} {{open", values: values, jsonEscape: false)
        XCTAssertEqual(body, "T=Call \"Q3\" / plan X={{unknown}} {{open")
    }

    func testEscape() {
        XCTAssertEqual(WebhookTemplate.escapeJSONString("a\"b\nc/d"), #"a\"b\nc/d"#)
    }
}
