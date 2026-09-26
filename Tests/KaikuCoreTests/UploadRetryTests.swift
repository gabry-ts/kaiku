import XCTest
@testable import KaikuCore

final class UploadRetryTests: XCTestCase {
    private func http(_ status: Int, _ body: String = "", retryAfter: String? = nil) -> UploadRetry.Failure {
        .http(status: status, body: body, retryAfter: retryAfter)
    }

    func testBackoffSequence() {
        XCTAssertEqual(UploadRetry.delay(after: http(502), attempt: 1), 1)
        XCTAssertEqual(UploadRetry.delay(after: http(502), attempt: 2), 2)
        XCTAssertEqual(UploadRetry.delay(after: http(502), attempt: 3), 4)
        XCTAssertNil(UploadRetry.delay(after: http(502), attempt: 4))
        XCTAssertNil(UploadRetry.delay(after: http(502), attempt: 0))
    }

    func testRetriesRateLimitAndServerErrors() {
        for status in [429, 500, 502, 503, 504, 599] {
            XCTAssertNotNil(UploadRetry.delay(after: http(status), attempt: 1), "\(status)")
        }
    }

    func testClientErrorsFailImmediately() {
        for status in [400, 401, 403, 404, 413, 422] {
            XCTAssertNil(UploadRetry.delay(after: http(status), attempt: 1), "\(status)")
        }
    }

    func testExhaustedQuotaIsNotRetried() {
        let body = #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#
        XCTAssertNil(UploadRetry.delay(after: http(429, body), attempt: 1))
        XCTAssertEqual(UploadRetry.delay(after: http(429, #"{"error":{"code":"rate_limit_exceeded"}}"#), attempt: 1), 1)
    }

    func testRetryAfterIsHonoured() {
        XCTAssertEqual(UploadRetry.delay(after: http(429, retryAfter: "20"), attempt: 1), 20)
        XCTAssertEqual(UploadRetry.delay(after: http(503, retryAfter: " 7 "), attempt: 1), 7)
        // Never shorter than the backoff.
        XCTAssertEqual(UploadRetry.delay(after: http(429, retryAfter: "0"), attempt: 3), 4)
        // Unparseable (HTTP-date) falls back to the backoff.
        XCTAssertEqual(UploadRetry.delay(after: http(429, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"), attempt: 2), 2)
        // Too long a wait: give up.
        XCTAssertNil(UploadRetry.delay(after: http(429, retryAfter: "300"), attempt: 1))
    }

    func testNetworkErrors() {
        XCTAssertEqual(UploadRetry.delay(after: .network(code: NSURLErrorNetworkConnectionLost), attempt: 1), 1)
        XCTAssertEqual(UploadRetry.delay(after: .network(code: NSURLErrorNotConnectedToInternet), attempt: 2), 2)
        XCTAssertNil(UploadRetry.delay(after: .network(code: NSURLErrorTimedOut), attempt: 1))
        XCTAssertNil(UploadRetry.delay(after: .network(code: NSURLErrorCancelled), attempt: 1))
    }
}
