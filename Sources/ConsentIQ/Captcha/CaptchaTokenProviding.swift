import Foundation

@MainActor
protocol CaptchaTokenProviding {
    func token() async throws -> String
}

/// Builds the captcha provider for an API URL and property key; the key binds each token to the property.
typealias CaptchaProviderFactory = @MainActor @Sendable (URL, String) -> (any CaptchaTokenProviding)?

enum CaptchaError: Error, CustomStringConvertible {
    case timedOut
    case pageLoadFailed
    case challengeFailed(code: String?)
    case cancelled

    var description: String {
        switch self {
        case .timedOut: return "timed out"
        case .pageLoadFailed: return "page load failed"
        case .challengeFailed(let code): return "challenge failed (\(code ?? "no code"))"
        case .cancelled: return "cancelled"
        }
    }
}

@MainActor
func makeDefaultCaptchaProvider(apiURL: URL, propertyKey: String) -> (any CaptchaTokenProviding)? {
    #if canImport(UIKit) && canImport(WebKit)
    return WebViewCaptchaProvider.shared(apiURL: apiURL, propertyKey: propertyKey)
    #else
    return nil
    #endif
}

extension PropertyConfig {
    var requiresCaptchaToken: Bool {
        requireCaptcha && turnstileSiteKey != nil
    }
}

extension ConsentIQAPIError {
    /// The server asks for a captcha when a request looks automated, whatever the property's setting.
    var isCaptchaRequired: Bool {
        statusCode == 428 && message == "captcha_required"
    }
}

/// Sends a submission and, when the server answers 428 captcha_required, solves one challenge and
/// sends it once more. A captcha that fails or is cancelled throws `CaptchaError`; nothing is resent.
@MainActor
func submitAnsweringChallenge(
    firstToken: String?,
    provider: () -> (any CaptchaTokenProviding)?,
    send: (String?) async throws -> ConsentSubmissionResult
) async throws -> ConsentSubmissionResult {
    do {
        return try await send(firstToken)
    } catch let error as ConsentIQAPIError where error.isCaptchaRequired {
        guard let provider = provider() else { throw error }
        let token = try await provider.token()
        return try await send(token)
    }
}
