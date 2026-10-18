#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class WebViewCaptchaProvider: NSObject, CaptchaTokenProviding {
    nonisolated static let pagePath = "/api/public/captcha/mobile"
    nonisolated static let challengeHost = "challenges.cloudflare.com"
    static let messageHandlerName = "consentiq"
    static let timeoutNanoseconds: UInt64 = 15_000_000_000

    private static var providers: [URL: WebViewCaptchaProvider] = [:]

    static func shared(apiURL: URL) -> WebViewCaptchaProvider {
        let pageURL = pageURL(apiURL: apiURL)
        if let provider = providers[pageURL] {
            return provider
        }
        let provider = WebViewCaptchaProvider(pageURL: pageURL)
        providers[pageURL] = provider
        return provider
    }

    nonisolated static func pageURL(apiURL: URL) -> URL {
        apiURL.appendingPathComponent(pagePath)
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
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.requestTimedOut(id)
            }
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
        guard webView.window == nil, let window = Self.keyWindow() else { return }
        window.addSubview(webView)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }?
            .keyWindow
    }

    private func execute() {
        guard var request = pending, !request.executed, let webView else { return }
        request.executed = true
        pending = request
        let id = request.id
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
        request.continuation.resume(with: result)
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

    fileprivate func receive(_ message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              Self.isPageOrigin(scheme: origin.protocol, host: origin.host, port: origin.port, pageURL: pageURL),
              let body = message.body as? String,
              let event = try? JSONDecoder().decode(PageMessage.self, from: Data(body.utf8)) else { return }

        switch event.type {
        case "ready":
            pageState = .ready
            execute()
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
        guard let pageScheme = pageURL.scheme?.lowercased(), let pageHost = pageURL.host?.lowercased() else { return false }
        return scheme.lowercased() == pageScheme
            && host.lowercased() == pageHost
            && effectivePort(port == 0 ? nil : port, scheme: pageScheme) == effectivePort(pageURL.port, scheme: pageScheme)
    }

    nonisolated static func allowsNavigation(to url: URL?, isMainFrame: Bool, pageURL: URL) -> Bool {
        guard let url else { return false }
        if isMainFrame {
            return isSamePage(url, pageURL)
        }
        if url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" {
            return true
        }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == challengeHost
            && effectivePort(url.port, scheme: "https") == 443
    }

    private nonisolated static func isSamePage(_ url: URL, _ pageURL: URL) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let page = URLComponents(url: pageURL, resolvingAgainstBaseURL: true),
              let scheme = page.scheme?.lowercased() else { return false }
        return candidate.scheme?.lowercased() == scheme
            && candidate.host?.lowercased() == page.host?.lowercased()
            && effectivePort(candidate.port, scheme: scheme) == effectivePort(page.port, scheme: scheme)
            && candidate.percentEncodedPath == page.percentEncodedPath
            && candidate.percentEncodedQuery == page.percentEncodedQuery
            && candidate.fragment == page.fragment
    }

    private nonisolated static func effectivePort(_ port: Int?, scheme: String) -> Int? {
        if let port {
            return port
        }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
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

// WKUserContentController retains its handlers, so a direct handler would keep the provider alive forever.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WebViewCaptchaProvider?

    init(target: WebViewCaptchaProvider) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
#endif
