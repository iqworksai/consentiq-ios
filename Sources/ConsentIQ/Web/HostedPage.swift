#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

enum HostedPage {
    static let messageHandlerName = "consentiq"
    nonisolated static let challengeHost = "challenges.cloudflare.com"

    nonisolated static func isPageOrigin(scheme: String, host: String, port: Int, pageURL: URL) -> Bool {
        guard let pageScheme = pageURL.scheme?.lowercased(), let pageHost = pageURL.host?.lowercased() else { return false }
        return scheme.lowercased() == pageScheme
            && host.lowercased() == pageHost
            && effectivePort(port == 0 ? nil : port, scheme: pageScheme) == effectivePort(pageURL.port, scheme: pageScheme)
    }

    @MainActor
    static func isPageMessage(_ message: WKScriptMessage, pageURL: URL) -> Bool {
        let origin = message.frameInfo.securityOrigin
        return message.frameInfo.isMainFrame
            && isPageOrigin(scheme: origin.protocol, host: origin.host, port: origin.port, pageURL: pageURL)
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

    nonisolated static func isSamePage(_ url: URL, _ pageURL: URL) -> Bool {
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

    nonisolated static func effectivePort(_ port: Int?, scheme: String) -> Int? {
        if let port {
            return port
        }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    @MainActor
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.keyWindow != nil }?
            .keyWindow
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

@MainActor
protocol ScriptMessageReceiving: AnyObject {
    func receive(_ message: WKScriptMessage)
}

// WKUserContentController retains its handlers, so a direct handler would keep its owner alive forever.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any ScriptMessageReceiving)?

    init(target: any ScriptMessageReceiving) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}
#endif
