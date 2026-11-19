#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class WebViewCaptchaProvider: NSObject, CaptchaTokenProviding, ScriptMessageReceiving {
    nonisolated static let pagePath = "/api/public/captcha/mobile"
    static let messageHandlerName = HostedPage.messageHandlerName
    static let timeoutNanoseconds: UInt64 = 15_000_000_000
    static let interactionTimeoutNanoseconds: UInt64 = 120_000_000_000

    private static var providers: [URL: WebViewCaptchaProvider] = [:]

    static func shared(apiURL: URL, propertyKey: String) -> WebViewCaptchaProvider {
        let pageURL = pageURL(apiURL: apiURL, propertyKey: propertyKey)
        if let provider = providers[pageURL] {
            return provider
        }
        let provider = WebViewCaptchaProvider(pageURL: pageURL)
        providers[pageURL] = provider
        return provider
    }

    /// The key binds each token to the property, so it cannot be spent on another one.
    nonisolated static func pageURL(apiURL: URL, propertyKey: String) -> URL {
        var components = URLComponents(url: apiURL.appendingPathComponent(pagePath), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: propertyKey)]
        return components?.url ?? apiURL.appendingPathComponent(pagePath)
    }

    private enum PageState {
        case idle
        case loading
        case ready
    }

    private struct PendingRequest {
        let id: Int
        let continuation: CheckedContinuation<String, Error>
        var executed = false
    }

    private struct PageMessage: Decodable {
        let type: String
        let token: String?
        let code: String?
    }

    let pageURL: URL
    private var webView: WKWebView?
    private var navigation: WKNavigation?
    private var pageState = PageState.idle
    private var pending: PendingRequest?
    private var timeoutTask: Task<Void, Never>?
    private var overlay: UIView?
    private var lastRequestId = 0
    private var isBusy = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    init(pageURL: URL) {
        self.pageURL = pageURL
        super.init()
    }

    deinit {
        let webView = webView
        Task { @MainActor in webView?.removeFromSuperview() }
    }

    func token() async throws -> String {
        await acquireTurn()
        defer { releaseTurn() }
        return try await withCheckedThrowingContinuation { continuation in
            lastRequestId += 1
            let id = lastRequestId
            pending = PendingRequest(id: id, continuation: continuation)
            scheduleTimeout(id, after: Self.timeoutNanoseconds)
            loadPageIfNeeded()
            if pageState == .ready {
                execute()
            }
        }
    }

    private func acquireTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func releaseTurn() {
        if turnWaiters.isEmpty {
            isBusy = false
        } else {
            turnWaiters.removeFirst().resume()
        }
    }

    private func loadPageIfNeeded() {
        let webView = webView ?? makeWebView()
        attachIfNeeded(webView)
        guard pageState == .idle else { return }
        pageState = .loading
        navigation = webView.load(URLRequest(url: pageURL))
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(WeakScriptMessageHandler(target: self), name: Self.messageHandlerName)

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        self.webView = webView
        return webView
    }

    // A detached web view may be throttled, so it rides invisibly in the key window.
    private func attachIfNeeded(_ webView: WKWebView) {
        guard webView.window == nil, let window = HostedPage.keyWindow() else { return }
        window.addSubview(webView)
    }

    private func scheduleTimeout(_ id: Int, after nanoseconds: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.requestTimedOut(id)
        }
    }

    private func execute() {
        guard var request = pending, !request.executed, let webView else { return }
        request.executed = true
        pending = request
        let id = request.id
        // The challenge stays hidden until the page posts `interactive`: only then does Cloudflare need a click.
        // The trailing `true` keeps the result serializable; an undefined result is reported as an error.
        webView.evaluateJavaScript("window.consentiqExecute(); true") { [weak self] _, error in
            guard error != nil else { return }
            self?.finish(id, .failure(CaptchaError.challengeFailed(code: nil)))
        }
    }

    private func requestTimedOut(_ id: Int) {
        guard pending?.id == id else { return }
        if pageState != .ready {
            pageState = .idle
        }
        finish(id, .failure(CaptchaError.timedOut))
    }

    private func finish(_ id: Int, _ result: Result<String, Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        conceal()
        request.continuation.resume(with: result)
    }

    // Shows the challenge over the app with a Cancel button, for a visitor Cloudflare wants to click.
    private func reveal(_ id: Int) {
        guard pending?.id == id, overlay == nil, let webView, let window = HostedPage.keyWindow() else { return }
        scheduleTimeout(id, after: Self.interactionTimeoutNanoseconds)

        let overlay = UIView(frame: window.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let card = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
        card.center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        card.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 12
        card.clipsToBounds = true

        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: card.bounds.width, height: 44))
        toolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel(id) }),
        ]
        card.addSubview(toolbar)

        webView.removeFromSuperview()
        webView.frame = CGRect(x: 0, y: 44, width: card.bounds.width, height: card.bounds.height - 44)
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = false
        card.addSubview(webView)

        overlay.addSubview(card)
        window.addSubview(overlay)
        self.overlay = overlay
    }

    private func conceal() {
        guard let overlay else { return }
        self.overlay = nil
        if let webView {
            webView.removeFromSuperview()
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            webView.accessibilityElementsHidden = true
            attachIfNeeded(webView)
        }
        overlay.removeFromSuperview()
    }

    private func cancel(_ id: Int) {
        finish(id, .failure(CaptchaError.cancelled))
    }

    private func finishPending(_ result: Result<String, Error>) {
        guard let id = pending?.id else { return }
        finish(id, result)
    }

    private func pageLoadFailed() {
        pageState = .idle
        navigation = nil
        finishPending(.failure(CaptchaError.pageLoadFailed))
    }

    func receive(_ message: WKScriptMessage) {
        guard HostedPage.isPageMessage(message, pageURL: pageURL),
              let body = message.body as? String,
              let event = try? JSONDecoder().decode(PageMessage.self, from: Data(body.utf8)) else { return }

        switch event.type {
        case "ready":
            pageState = .ready
            execute()
        case "interactive":
            if let id = pending?.id, pending?.executed == true {
                reveal(id)
            }
        case "token":
            guard pending?.executed == true, let token = event.token, !token.isEmpty else { return }
            finishPending(.success(token))
        case "error":
            if pageState != .ready {
                pageState = .idle
            }
            finishPending(.failure(CaptchaError.challengeFailed(code: event.code)))
        default:
            break
        }
    }

    nonisolated static func isPageOrigin(scheme: String, host: String, port: Int, pageURL: URL) -> Bool {
        HostedPage.isPageOrigin(scheme: scheme, host: host, port: port, pageURL: pageURL)
    }

    nonisolated static func allowsNavigation(to url: URL?, isMainFrame: Bool, pageURL: URL) -> Bool {
        HostedPage.allowsNavigation(to: url, isMainFrame: isMainFrame, pageURL: pageURL)
    }
}

extension WebViewCaptchaProvider: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let targetFrame = navigationAction.targetFrame else {
            decisionHandler(.cancel)
            return
        }
        let allowed = Self.allowsNavigation(to: navigationAction.request.url, isMainFrame: targetFrame.isMainFrame, pageURL: pageURL)
        decisionHandler(allowed ? .allow : .cancel)
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
#endif
