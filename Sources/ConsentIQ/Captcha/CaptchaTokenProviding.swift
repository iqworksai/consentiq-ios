import Foundation

@MainActor
protocol CaptchaTokenProviding {
    func token() async throws -> String
}

typealias CaptchaProviderFactory = @MainActor @Sendable (URL) -> (any CaptchaTokenProviding)?

enum CaptchaError: Error, CustomStringConvertible {
    case timedOut
    case pageLoadFailed
    case challengeFailed(code: String?)

    var description: String {
        switch self {
        case .timedOut: return "timed out"
        case .pageLoadFailed: return "page load failed"
        case .challengeFailed(let code): return "challenge failed (\(code ?? "no code"))"
        }
    }
}

@MainActor
func makeDefaultCaptchaProvider(apiURL: URL) -> (any CaptchaTokenProviding)? {
    #if canImport(UIKit) && canImport(WebKit)
    return WebViewCaptchaProvider.shared(apiURL: apiURL)
    #else
    return nil
    #endif
}

extension PropertyConfig {
    var requiresCaptchaToken: Bool {
        requireCaptcha && turnstileSiteKey != nil
    }
}
