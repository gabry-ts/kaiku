import XCTest
@testable import KaikuCore

final class MeetingLinkTests: XCTestCase {
    func testMeetLinks() {
        let link = MeetingLink("https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link?.platform, .meet)
        XCTAssertEqual(link?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingLink("meet.google.com/abc-defg-hij")?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingLink("https://meet.google.com/abc-defg-hij?authuser=1")?.url.absoluteString,
                       "https://meet.google.com/abc-defg-hij?authuser=1")
    }

    func testTeamsLinks() {
        let join = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%3a%221%22%7d"
        XCTAssertEqual(MeetingLink(join)?.platform, .teams)
        XCTAssertEqual(MeetingLink(join)?.url.absoluteString, join)
        XCTAssertEqual(MeetingLink("https://teams.microsoft.com/meet/123456789?p=abc")?.platform, .teams)
        XCTAssertEqual(MeetingLink("https://teams.live.com/meet/9876543210")?.platform, .teams)
    }

    func testWebexLinks() {
        XCTAssertEqual(MeetingLink("https://acme.webex.com/meet/jane.doe")?.platform, .webex)
        XCTAssertEqual(MeetingLink("https://acme.webex.com/acme/j.php?MTID=m1234abcd")?.platform, .webex)
        XCTAssertEqual(MeetingLink("https://acme.my.webex.com/join/jdoe")?.platform, .webex)
        XCTAssertNil(MeetingLink("https://www.webex.com/"))
        XCTAssertNil(MeetingLink("https://www.webex.com/pricing"))
    }

    func testFaceTimeLinks() {
        let link = "https://facetime.apple.com/join#v=1&p=AbCdEf123&k=XyZ987"
        XCTAssertEqual(MeetingLink(link)?.platform, .faceTime)
        XCTAssertEqual(MeetingLink(link)?.url.absoluteString, link)
        XCTAssertNil(MeetingLink("https://facetime.apple.com/"))
    }

    func testLinksInsideText() {
        let notes = "Join here: https://meet.google.com/abc-defg-hij.\nOr dial in."
        XCTAssertEqual(MeetingLink.find(in: notes)?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        let both = "Teams (https://teams.microsoft.com/meet/111?p=x), backup meet.google.com/abc-defg-hij"
        XCTAssertEqual(MeetingLink.find(in: both)?.platform, .teams)
        XCTAssertEqual(MeetingLink.find(in: both)?.url.absoluteString, "https://teams.microsoft.com/meet/111?p=x")
    }

    func testOtherLinksAreIgnored() {
        XCTAssertNil(MeetingLink("https://zoom.us/j/123456789"))
        XCTAssertNil(MeetingLink("https://meet.google.com/"))
        XCTAssertNil(MeetingLink("https://teams.microsoft.com/"))
        XCTAssertNil(MeetingLink(""))
    }
}
