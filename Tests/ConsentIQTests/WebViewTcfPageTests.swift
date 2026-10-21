#if canImport(UIKit) && canImport(WebKit)
import XCTest
import UIKit
import WebKit
@testable import ConsentIQ

@MainActor
final class WebViewTcfPageTests: XCTestCase {
    private let pageURL = TcfSession.pageURL(apiURL: Fixtures.apiURL, propertyKey: "abc-123")

    private func allows(_ url: String, mainFrame: Bool) -> Bool {
        HostedPage.allowsNavigation(to: URL(string: url), isMainFrame: mainFrame, pageURL: pageURL)
    }

    func testMainFrameMayOnlyLoadThePageWithItsKey() {
        XCTAssertTrue(allows("https://consent.example.test/api/public/tcf/mobile?key=abc-123", mainFrame: true))
        XCTAssertFalse(allows("https://consent.example.test/api/public/tcf/mobile?key=other", mainFrame: true))
        XCTAssertFalse(allows("https://consent.example.test/api/public/tcf/mobile", mainFrame: true))
        XCTAssertFalse(allows("https://vendor.example/privacy", mainFrame: true))
        XCTAssertTrue(allows("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x", mainFrame: false))
        XCTAssertFalse(allows("https://vendor.example/frame", mainFrame: false))
    }

    func testOnlyWebLinksOpenExternally() {
        XCTAssertTrue(WebViewTcfPage.isExternalLink(URL(string: "https://vendor.example/privacy")))
        XCTAssertTrue(WebViewTcfPage.isExternalLink(URL(string: "http://vendor.example/privacy")))
        XCTAssertFalse(WebViewTcfPage.isExternalLink(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(WebViewTcfPage.isExternalLink(URL(string: "tel:123")))
        XCTAssertFalse(WebViewTcfPage.isExternalLink(nil))
    }

    func testFirstPromptIsFullScreenAndCannotBeSwipedAway() {
        let controller = TcfViewController(webView: WKWebView(), reopen: false) {}
        XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
        XCTAssertEqual(controller.modalTransitionStyle, .coverVertical)
        XCTAssertTrue(controller.isModalInPresentation)

        let reopened = TcfViewController(webView: WKWebView(), reopen: true) {}
        XCTAssertFalse(reopened.isModalInPresentation)
    }

    func testWebViewRunsEdgeToEdgeOnThePageBackground() {
        let webView = WKWebView()
        let controller = TcfViewController(webView: webView, reopen: false) {}
        controller.loadViewIfNeeded()

        XCTAssertTrue(webView.superview === controller.view)
        XCTAssertEqual(webView.autoresizingMask, [.flexibleWidth, .flexibleHeight])
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(controller.view.backgroundColor?.resolvedColor(with: light), .white)
        XCTAssertEqual(
            controller.view.backgroundColor?.resolvedColor(with: dark),
            UIColor(red: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1)
        )
    }

    func testPageWebViewHasNoInsetsAndIsTransparentUntilPresented() throws {
        let page = WebViewTcfPage(pageURL: pageURL, presenter: nil)
        var events: [TcfPageEvent] = []
        page.onEvent = { events.append($0) }

        page.load()
        let webView = try XCTUnwrap(page.webView)

        XCTAssertFalse(webView.isOpaque)
        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never)
        XCTAssertFalse(webView.isUserInteractionEnabled)
        XCTAssertLessThan(webView.alpha, 0.05)

        page.close()
        XCTAssertNil(webView.navigationDelegate)
        XCTAssertNil(webView.superview)
    }

    func testPrewarmWaitsForAnActiveKeyWindowInsteadOfLoadingDetached() throws {
        let page = WebViewTcfPage(pageURL: pageURL, presenter: nil)
        page.load()
        let webView = try XCTUnwrap(page.webView)

        XCTAssertEqual(page.isWaitingForWindow, HostedPage.keyWindow() == nil)
        if page.isWaitingForWindow {
            XCTAssertNil(webView.url)
            XCTAssertNil(webView.superview)
        }
        XCTAssertEqual(webView.autoresizingMask, [.flexibleWidth, .flexibleHeight])
        page.close()
        XCTAssertFalse(page.isWaitingForWindow)
    }

    func testPresentFromAHostOutsideAWindowFails() {
        let page = WebViewTcfPage(pageURL: pageURL, presenter: UIViewController())
        var failures: [String] = []
        page.onEvent = { event in
            if case .failed(let code) = event { failures.append(code) }
        }
        page.load()

        page.present(reopen: false)

        XCTAssertEqual(failures, [TcfError.noPresenter])
        page.close()
    }

    func testExternalDismissalIsReportedOnceAndNotWhenFinishing() {
        var dismissed = 0
        let controller = TcfViewController(webView: WKWebView(), reopen: true) { dismissed += 1 }
        controller.loadViewIfNeeded()

        controller.viewDidDisappear(false)
        controller.viewDidDisappear(false)
        XCTAssertEqual(dismissed, 1)

        let finishing = TcfViewController(webView: WKWebView(), reopen: true) { dismissed += 1 }
        finishing.isFinishing = true
        finishing.viewDidDisappear(false)
        XCTAssertEqual(dismissed, 1)
    }

    func testTopmostWalksPresentedControllers() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let child = UIViewController()
        root.present(child, animated: false)

        XCTAssertTrue(WebViewTcfPage.topmost(from: root) === child)
        root.dismiss(animated: false)
        window.isHidden = true
    }

    func testPresentWithoutAPresenterFails() {
        let page = WebViewTcfPage(pageURL: pageURL, presenter: nil)
        var failures: [String] = []
        page.onEvent = { event in
            if case .failed(let code) = event { failures.append(code) }
        }

        page.present(reopen: false)

        XCTAssertEqual(failures, [TcfError.noPresenter])
    }
}
#endif
