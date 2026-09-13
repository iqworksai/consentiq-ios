import Foundation
import Combine

public struct FormConsentResult: Sendable {
    public let consentId: String
    public let proofHash: String
    public let consents: MarketingConsentState
}

@MainActor
public final class FormConsent: ObservableObject {
    public nonisolated static let defaultChannels = ["email", "sms", "whatsapp", "push"]

    @Published public private(set) var consents: MarketingConsentState
    @Published public private(set) var isSubmitting = false

    public var subjectId: String
    public var subjectType: SubjectType
    public var onConsentSubmitted: ((FormConsentResult) -> Void)?
    public var onConsentChange: ((MarketingConsentState) -> Void)?

    private let channels: [String]
    private let apiClient: ConsentIQAPIClient
    private let logger: ConsentIQLogger

    public init(
        propertyKey: String,
        apiURL: URL = ConsentIQAPIClient.defaultAPIURL,
        subjectId: String,
        subjectType: SubjectType = .user,
        channels: [String] = FormConsent.defaultChannels,
        session: URLSession = .shared,
        debug: Bool = false,
        onConsentSubmitted: ((FormConsentResult) -> Void)? = nil,
        onConsentChange: ((MarketingConsentState) -> Void)? = nil
    ) {
        self.subjectId = subjectId
        self.subjectType = subjectType
        self.channels = channels
        self.logger = ConsentIQLogger(debugEnabled: debug)
        self.apiClient = ConsentIQAPIClient(propertyKey: propertyKey, apiURL: apiURL, session: session, logger: logger)
        self.onConsentSubmitted = onConsentSubmitted
        self.onConsentChange = onConsentChange
        self.consents = Self.cleared(channels)
    }

    public convenience init(
        consentIQ: ConsentIQ,
        subjectId: String? = nil,
        subjectType: SubjectType = .user,
        channels: [String] = FormConsent.defaultChannels,
        onConsentSubmitted: ((FormConsentResult) -> Void)? = nil,
        onConsentChange: ((MarketingConsentState) -> Void)? = nil
    ) {
        let configuration = consentIQ.configuration
        self.init(
            propertyKey: configuration?.propertyKey ?? "",
            apiURL: configuration?.apiURL ?? ConsentIQAPIClient.defaultAPIURL,
            subjectId: subjectId ?? consentIQ.subjectId ?? "",
            subjectType: subjectType,
            channels: channels,
            debug: configuration?.debug ?? false,
            onConsentSubmitted: onConsentSubmitted,
            onConsentChange: onConsentChange
        )
    }

    public func toggle(_ channel: String) {
        set(channel, !(consents[channel] ?? false))
    }

    public func set(_ channel: String, _ value: Bool) {
        consents[channel] = value
        onConsentChange?(consents)
    }

    @discardableResult
    public func submit() async -> FormConsentResult? {
        guard !subjectId.isEmpty else {
            logger.debug("Skipping form consent submit: no subject id")
            return nil
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let response = try await apiClient.submitConsent(ConsentSubmission(
                propertyKey: apiClient.propertyKey,
                subjectId: subjectId,
                subjectType: subjectType,
                marketingConsents: consents,
                consentMethod: .form
            ))
            let result = FormConsentResult(consentId: response.consentId, proofHash: response.proofHash, consents: consents)
            onConsentSubmitted?(result)
            return result
        } catch {
            logger.error("Failed to submit form consent: \(error.localizedDescription)")
            return nil
        }
    }

    public func reset() {
        consents = Self.cleared(channels)
    }

    private static func cleared(_ channels: [String]) -> MarketingConsentState {
        Dictionary(channels.map { ($0, false) }, uniquingKeysWith: { first, _ in first })
    }
}
