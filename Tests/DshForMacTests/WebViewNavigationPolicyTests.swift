import XCTest
@testable import DshForMac

final class WebViewNavigationPolicyTests: XCTestCase {
    private let port = 3080

    func testTreatsMissingAndAboutURLsAsBlankPopups() {
        XCTAssertTrue(WebViewNavigationPolicy.isBlankPopup(nil))
        for value in ["about:blank", "about:srcdoc", "about:blank#blocked"] {
            XCTAssertTrue(WebViewNavigationPolicy.isBlankPopup(URL(string: value)), value)
        }
    }

    func testOnlyConfiguredLoopbackAddressIsLocalDSH() throws {
        func url(_ value: String) throws -> URL {
            try XCTUnwrap(URL(string: value))
        }
        XCTAssertTrue(WebViewNavigationPolicy.isLocalDSHURL(try url("http://127.0.0.1:3080/"), port: port))
        XCTAssertFalse(WebViewNavigationPolicy.isLocalDSHURL(try url("http://127.0.0.1:3081/"), port: port))
        XCTAssertFalse(WebViewNavigationPolicy.isLocalDSHURL(try url("http://localhost:3080/"), port: port))
        XCTAssertFalse(WebViewNavigationPolicy.isLocalDSHURL(try url("https://127.0.0.1:3080/"), port: port))
        XCTAssertFalse(WebViewNavigationPolicy.isLocalDSHURL(
            try url("https://platform.deepseek.com/dsh/authorize"), port: port
        ))
    }

    func testClassifiesNavigationDestinations() throws {
        func url(_ value: String) throws -> URL {
            try XCTUnwrap(URL(string: value))
        }
        XCTAssertEqual(
            WebViewNavigationPolicy.destination(for: try url("http://127.0.0.1:3080/session"), port: port),
            .localDSH
        )
        XCTAssertEqual(
            WebViewNavigationPolicy.destination(for: try url("about:blank"), port: port),
            .blankPopup
        )
        XCTAssertEqual(
            WebViewNavigationPolicy.destination(
                for: try url("https://platform.deepseek.com/dsh/authorize?code=1"), port: port
            ),
            .external
        )
        XCTAssertEqual(
            WebViewNavigationPolicy.destination(for: try url("file:///tmp/report.pdf"), port: port),
            .external
        )
    }

    func testOnlyWebAddressesOpenDirectlyInBrowser() throws {
        func url(_ value: String) throws -> URL {
            try XCTUnwrap(URL(string: value))
        }
        XCTAssertTrue(WebViewNavigationPolicy.canOpenDirectlyInBrowser(
            try url("https://platform.deepseek.com/dsh/authorize")
        ))
        XCTAssertTrue(WebViewNavigationPolicy.canOpenDirectlyInBrowser(
            try url("http://127.0.0.1:8080/callback")
        ))
        XCTAssertFalse(WebViewNavigationPolicy.canOpenDirectlyInBrowser(
            try url("mailto:support@example.com")
        ))
        XCTAssertFalse(WebViewNavigationPolicy.canOpenDirectlyInBrowser(
            try url("file:///tmp/report.pdf")
        ))
        XCTAssertFalse(WebViewNavigationPolicy.canOpenDirectlyInBrowser(try url("about:blank")))
    }

    func testCapsConcurrentPopupWebViews() {
        XCTAssertEqual(WebViewNavigationPolicy.maximumConcurrentPopups, 4)
        for count in 0..<WebViewNavigationPolicy.maximumConcurrentPopups {
            XCTAssertTrue(WebViewNavigationPolicy.canCreatePopup(existingCount: count), "\(count)")
        }
        XCTAssertFalse(
            WebViewNavigationPolicy.canCreatePopup(
                existingCount: WebViewNavigationPolicy.maximumConcurrentPopups
            )
        )
    }
}
