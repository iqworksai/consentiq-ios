import Foundation
import Combine

@MainActor
public final class ConsentIQ: ObservableObject {
    public nonisolated static let shared = ConsentIQ()

    public nonisolated static let defaultConsent: ConsentState = [
        ConsentCategory.necessary: true,
        ConsentCategory.analytics: false,
        ConsentCategory.marketing: false,
        ConsentCategory.preferences: false,
        ConsentCategory.social: false,
    ]

    @Published public private(set) var consent: ConsentState = ConsentIQ.defaultConsent
    @Published public private(set) var marketingConsent: MarketingConsentState = [:]
    @Published public private(set) var config: PropertyConfig?
    @Published public private(set) var isLoading = true
    @Published public private(set) var isSheetVisible = false
    @Published public private(set) var language = "en"
    @Published public private(set) var regulation: String?

    public private(set) var subjectId: String?
    public private(set) var configuration: ConsentIQConfig?
    public private(set) var initializationTask: Task<Void, Never>?

    let storage: ConsentStorage
    var logSink: ((String) -> Void)?

    private let sessionConfiguration: URLSessionConfiguration
    private var apiClient: ConsentIQAPIClient?
    private var logger = ConsentIQLogger()
    private var hasWarnedAboutCaptcha = false

    public nonisolated init(storage: ConsentStorage = ConsentStorage(), urlSessionConfiguration: URLSessionConfiguration = .default) {
        self.storage = storage
        self.sessionConfiguration = urlSessionConfiguration
    }

    public func configure(_ config: ConsentIQConfig) {
        initializationTask?.cancel()
        initializationTask = Task { [weak self] in
            await self?.initialize(config)
        }
    }

    public func initialize(_ config: ConsentIQConfig) async {
        configuration = config
        logger = ConsentIQLogger(debugEnabled: config.debug, sink: logSink)
        let client = ConsentIQAPIClient(
            propertyKey: config.propertyKey,
            apiURL: config.apiURL,
            session: URLSession(configuration: sessionConfiguration),
            logger: logger
        )
        apiClient = client
        isLoading = true

        do {
            subjectId = resolveSubjectId(config)

            let propertyConfig = try await client.getConfig()
            self.config = propertyConfig
            regulation = propertyConfig.resolvedRegulation
            language = config.language ?? propertyConfig.property.defaultLanguage ?? "en"

            if propertyConfig.requireCaptcha, !hasWarnedAboutCaptcha {
                hasWarnedAboutCaptcha = true
                logger.warning(ConsentIQLogger.captchaWarning)
            }

            var foundExistingConsent = false
            if let subjectId {
                foundExistingConsent = await restoreConsent(client: client, subjectId: subjectId)
            }

            isLoading = false

            if config.autoShow, !foundExistingConsent {
                isSheetVisible = true
                config.onOpen?()
            }
        } catch {
            logger.error("Failed to initialize: \(error.localizedDescription)")
            isLoading = false
        }
    }

    public func hasConsent(_ category: String) -> Bool {
        consent[category] == true
    }

    public func hasMarketingConsent(_ channel: String) -> Bool {
        marketingConsent[channel] == true
    }

    public func acceptAll() async {
        var accepted = ConsentIQ.defaultConsent
        if let config {
            for category in config.categories where category.enabled {
                accepted[category.code] = true
            }
        } else {
            for key in accepted.keys {
                accepted[key] = true
            }
        }
        accepted = accepted.forcingNecessary()

        consent = accepted
        isSheetVisible = false
        configuration?.onAccept?(ConsentOutcome(scope: .all, consent: accepted))
        await submit(cookieConsents: accepted, marketingConsents: marketingConsent)
    }

    public func rejectAll() async {
        let rejected = ConsentIQ.defaultConsent
        consent = rejected
        isSheetVisible = false
        configuration?.onReject?(ConsentOutcome(consent: rejected))
        await submit(cookieConsents: rejected, marketingConsents: [:])
    }

    public func savePreferences(_ selection: ConsentState) async {
        let next = selection.forcingNecessary()
        consent = next
        isSheetVisible = false
        configuration?.onSave?(ConsentOutcome(consent: next))
        await submit(cookieConsents: next, marketingConsents: marketingConsent)
    }

    public func updateConsent(_ updates: ConsentState) async {
        let next = consent.merging(updates) { _, new in new }.forcingNecessary()
        consent = next
        await submit(cookieConsents: next, marketingConsents: marketingConsent)
    }

    public func updateMarketingConsent(_ updates: MarketingConsentState) async {
        let next = marketingConsent.merging(updates) { _, new in new }
        marketingConsent = next
        await submit(cookieConsents: consent, marketingConsents: next)
    }

    public func showSheet() {
        isSheetVisible = true
        configuration?.onOpen?()
    }

    public func hideSheet() {
        isSheetVisible = false
    }

    // Guarded so the presentation layer can route every dismissal here: a programmatic hide also
    // ends the sheet, and only a visitor back-out may reach onClose.
    public func dismissSheet() {
        guard isSheetVisible else { return }
        isSheetVisible = false
        configuration?.onClose?()
    }

    public func resetConsent() {
        consent = ConsentIQ.defaultConsent
        marketingConsent = [:]
        storage.clearAll()
        if let configuration {
            subjectId = resolveSubjectId(configuration)
        }
    }

    public func acceptAll() {
        Task { await acceptAll() }
    }

    public func rejectAll() {
        Task { await rejectAll() }
    }

    public func savePreferences(_ selection: ConsentState) {
        Task { await savePreferences(selection) }
    }

    public func updateConsent(_ updates: ConsentState) {
        Task { await updateConsent(updates) }
    }

    public func updateMarketingConsent(_ updates: MarketingConsentState) {
        Task { await updateMarketingConsent(updates) }
    }

    private func restoreConsent(client: ConsentIQAPIClient, subjectId: String) async -> Bool {
        let lookup: ConsentLookup?
        do {
            lookup = try await client.getConsent(subjectId: subjectId)
        } catch {
            logger.debug("Consent lookup failed: \(error.localizedDescription)")
            lookup = nil
        }

        if let saved = lookup?.consent {
            consent = saved.cookieConsents.forcingNecessary()
            if let marketing = saved.marketingConsents {
                marketingConsent = marketing
            }
            storage.saveConsent(consent)
            return true
        }
        if lookup?.expired == true {
            storage.clearConsent()
            return false
        }
        if let local = storage.loadConsent() {
            consent = local.forcingNecessary()
            return true
        }
        return false
    }

    private func resolveSubjectId(_ config: ConsentIQConfig) -> String? {
        if let provided = config.subjectId, !provided.isEmpty {
            return provided
        }
        return config.autoGenerateSubjectId ? storage.getOrCreateSubjectId() : nil
    }

    private func submit(cookieConsents: ConsentState, marketingConsents: MarketingConsentState) async {
        guard let subjectId, let apiClient else {
            logger.debug("Skipping consent submit: no subject id")
            return
        }
        do {
            _ = try await apiClient.submitConsent(ConsentSubmission(
                propertyKey: apiClient.propertyKey,
                subjectId: subjectId,
                cookieConsents: cookieConsents,
                marketingConsents: marketingConsents,
                consentMethod: .sdk
            ))
            storage.saveConsent(cookieConsents)
            configuration?.onConsentChange?(cookieConsents, marketingConsents)
        } catch {
            logger.error("Failed to submit consent: \(error.localizedDescription)")
        }
    }
}
