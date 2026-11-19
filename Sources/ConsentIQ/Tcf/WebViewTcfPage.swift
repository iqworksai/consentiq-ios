import Foundation
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#endif

@MainActor
func makeDefaultTcfPage(pageURL: URL, presenter: AnyObject?) -> (any TcfPageHosting)? {
    #if canImport(UIKit) && canImport(WebKit)
    return WebViewTcfPage(pageURL: pageURL, presenter: presenter as? UIViewController)
    #else
    return nil
    #endif
}

#if canImport(UIKit) && canImport(WebKit)
@MainActor
final class WebViewTcfPage: NSObject, TcfPageHosting, ScriptMessageReceiving {
    static let presentWatchdogNanoseconds: UInt64 = 5_000_000_000

    var onEvent: ((TcfPageEvent) -> Void)?

    let pageURL: URL
    private weak var presenter: UIViewController?
    private(set) var webView: WKWebView?
    private(set) var isWaitingForWindow = false
    private var navigation: WKNavigation?
    private var controller: TcfViewController?
    private var windowObservers: [NSObjectProtocol] = []
    private var presentWatchdog: Task<Void, Never>?

    init(pageURL: URL, presenter: UIViewController?) {
        self.pageURL = pageURL
        self.presenter = presenter
        super.init()
    }

    func load() {
        let webView = makeWebView()
        if attachHidden(webView) {
            navigation = webView.load(URLRequest(url: pageURL))
        } else {
            waitForWindow()
        }
    }

    func start(_ options: TcfStartOptions) {
        guard let webView else { return }
        webView.callAsyncJavaScript(
            "window.consentiqTcfStart(options); return true;",
            arguments: ["options": options.arguments],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard case .failure = result else { return }
            self?.onEvent?(.failed(code: TcfError.startFailed))
        }
    }

    func present(reopen: Bool) {
        guard let webView, let host = Self.topmost(from: presenter ?? HostedPage.topViewController()),
              host.viewIfLoaded?.window != nil else {
            onEvent?(.failed(code: TcfError.noPresenter))
            return
        }
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
        let controller = TcfViewController(webView: webView, reopen: reopen) { [weak self] in
            self?.onEvent?(.dismissedExternally)
        }
        self.controller = controller
        presentWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.presentWatchdogNanoseconds)
            guard !Task.isCancelled else { return }
            self?.onEvent?(.failed(code: TcfError.noPresenter))
        }
        host.present(controller, animated: true) { [weak self] in
            self?.presentWatchdog?.cancel()
            self?.presentWatchdog = nil
        }
        // UIKit refuses some presentations (one already in flight, a detached host) with only a console warning.
        if controller.presentingViewController == nil {
            presentWatchdog?.cancel()
            presentWatchdog = nil
            onEvent?(.failed(code: TcfError.noPresenter))
        }
    }

    func close() {
        onEvent = nil
        presentWatchdog?.cancel()
        presentWatchdog = nil
        stopWaitingForWindow()
        let webView = webView
        self.webView = nil
        navigation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: HostedPage.messageHandlerName)
        if let controller, controller.presentingViewController != nil, !controller.isBeingDismissed {
            controller.isFinishing = true
            controller.dismiss(animated: true) { webView?.removeFromSuperview() }
        } else {
            controller?.isFinishing = true
            webView?.removeFromSuperview()
        }
        controller = nil
    }

    func receive(_ message: WKScriptMessage) {
        guard HostedPage.isPageMessage(message, pageURL: pageURL), let body = message.body as? String else { return }
        onEvent?(.message(body))
    }

    static func topmost(from root: UIViewController?) -> UIViewController? {
        var top = root
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: HostedPage.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = TcfViewController.pageBackground
        webView.underPageBackgroundColor = TcfViewController.pageBackground
        webView.scrollView.backgroundColor = TcfViewController.pageBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        self.webView = webView
        return webView
    }

    // A detached web view may be throttled, so the prewarmed page sits invisibly behind the app's views.
    private func attachHidden(_ webView: WKWebView) -> Bool {
        guard let window = HostedPage.keyWindow() else { return false }
        webView.frame = window.bounds
        window.insertSubview(webView, at: 0)
        return true
    }

    private func waitForWindow() {
        isWaitingForWindow = true
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.windowMayBeAvailable() }
            })
        }
    }

    private func windowMayBeAvailable() {
        guard isWaitingForWindow, let webView, attachHidden(webView) else { return }
        stopWaitingForWindow()
        navigation = webView.load(URLRequest(url: pageURL))
    }

    private func stopWaitingForWindow() {
        isWaitingForWindow = false
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
    }

    private func pageLoadFailed() {
        navigation = nil
        onEvent?(.failed(code: TcfError.pageLoadFailed))
    }

    nonisolated static func isExternalLink(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension WebViewTcfPage: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        if let targetFrame = navigationAction.targetFrame,
           HostedPage.allowsNavigation(to: url, isMainFrame: targetFrame.isMainFrame, pageURL: pageURL) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        let userOpened = navigationAction.targetFrame == nil || navigationAction.navigationType == .linkActivated
        if userOpened, Self.isExternalLink(url), let url {
            UIApplication.shared.open(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              !(200..<300).contains(response.statusCode) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        pageLoadFailed()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        pageLoadFailed()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        pageLoadFailed()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoadFailed()
    }
}

@MainActor
final class TcfViewController: UIViewController {
    // Matches the hosted page's own light and dark backgrounds, so nothing flashes behind it.
    static let pageBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1)
            : .white
    }

    let webView: WKWebView
    var isFinishing = false
    private let onDismissedExternally: () -> Void

    init(webView: WKWebView, reopen: Bool, onDismissedExternally: @escaping () -> Void) {
        self.webView = webView
        self.onDismissedExternally = onDismissedExternally
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .coverVertical
        isModalInPresentation = !reopen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TcfViewController does not support storyboards")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = Self.pageBackground
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        self.view = view
    }

    // A full-screen presentation never reports to a presentation delegate, so an app dismissing it is caught here.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !isFinishing, isBeingDismissed || presentingViewController == nil else { return }
        isFinishing = true
        onDismissedExternally()
    }
}
#endif
