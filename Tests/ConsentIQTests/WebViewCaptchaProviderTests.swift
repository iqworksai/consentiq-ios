#if canImport(UIKit) && canImport(WebKit)
import XCTest
@testable import ConsentIQ

final class WebViewCaptchaProviderTests: XCTestCase {
    private let pageURL = WebViewCaptchaProvider.pageURL(apiURL: Fixtures.apiURL)

    private func allows(_ url: String, mainFrame: Bool) -> Bool {
        WebViewCaptchaProvider.allowsNavigation(to: URL(string: url), isMainFrame: mainFrame, pageURL: pageURL)
    }

    private func isPageOrigin(_ scheme: String, _ host: String, _ port: Int = 0) -> Bool {
        WebViewCaptchaProvider.isPageOrigin(scheme: scheme, host: host, port: port, pageURL: pageURL)
    }

    func testPageURLIsUnderTheAPIURL() throws {
        XCTAssertEqual(pageURL.absoluteString, "https://consent.example.test/api/public/captcha/mobile")
        let trailingSlash = try XCTUnwrap(URL(string: "https://consent.iqworks.ai/"))
        XCTAssertEqual(
            WebViewCaptchaProvider.pageURL(apiURL: trailingSlash).absoluteString,
            "https://consent.iqworks.ai/api/public/captcha/mobile"
        )
    }

    func testMainFrameMayOnlyLoadThePage() {
        XCTAssertTrue(allows("https://consent.example.test/api/public/captcha/mobile", mainFrame: true))
        XCTAssertTrue(allows("HTTPS://Consent.Example.Test:443/api/public/captcha/mobile", mainFrame: true))

        XCTAssertFalse(allows("https://consent.example.test/api/public/captcha/mobile?next=x", mainFrame: true))
        XCTAssertFalse(allows("https://consent.example.test/api/public/captcha/mobile/x", mainFrame: true))
        XCTAssertFalse(allows("https://consent.example.test/", mainFrame: true))
        XCTAssertFalse(allows("http://consent.example.test/api/public/captcha/mobile", mainFrame: true))
        XCTAssertFalse(allows("https://consent.example.test:8443/api/public/captcha/mobile", mainFrame: true))
        XCTAssertFalse(allows("https://evil.test/api/public/captcha/mobile", mainFrame: true))
        XCTAssertFalse(allows("https://challenges.cloudflare.com/turnstile", mainFrame: true))
        XCTAssertFalse(allows("about:blank", mainFrame: true))
        XCTAssertFalse(WebViewCaptchaProvider.allowsNavigation(to: nil, isMainFrame: true, pageURL: pageURL))
    }

    func testSubframesMayOnlyLoadTurnstile() {
        XCTAssertTrue(allows("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/turnstile/if/ov2", mainFrame: false))
        XCTAssertTrue(allows("about:blank", mainFrame: false))
        XCTAssertTrue(allows("about:srcdoc", mainFrame: false))

        XCTAssertFalse(allows("http://challenges.cloudflare.com/x", mainFrame: false))
        XCTAssertFalse(allows("https://challenges.cloudflare.com:8443/x", mainFrame: false))
        XCTAssertFalse(allows("https://challenges.cloudflare.com.evil.test/x", mainFrame: false))
        XCTAssertFalse(allows("https://consent.example.test/api/public/captcha/mobile", mainFrame: false))
        XCTAssertFalse(allows("data:text/html,hello", mainFrame: false))
        XCTAssertFalse(allows("about:config", mainFrame: false))
    }

    func testMessagesAreAcceptedOnlyFromThePageOrigin() {
        XCTAssertTrue(isPageOrigin("https", "consent.example.test"))
        XCTAssertTrue(isPageOrigin("https", "consent.example.test", 443))
        XCTAssertTrue(isPageOrigin("HTTPS", "Consent.Example.Test"))

        XCTAssertFalse(isPageOrigin("http", "consent.example.test"))
        XCTAssertFalse(isPageOrigin("https", "consent.example.test", 8443))
        XCTAssertFalse(isPageOrigin("https", "challenges.cloudflare.com"))
        XCTAssertFalse(isPageOrigin("https", "evil.test"))
    }
}
#endif
