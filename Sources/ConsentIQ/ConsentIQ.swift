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

    @Published public internal(set) var consent: ConsentState = ConsentIQ.defaultConsent
    @Published public private(set) var marketingConsent: MarketingConsentState = [:]
    @Published public private(set) var config: PropertyConfig?
    @Published public private(set) var isLoading = true
    @Published public private(set) var isSheetVisible = false
    @Published public private(set) var language = "en"
    @Published public private(set) var regulation: String?
    @Published public internal(set) var isTcfActive = false

    public private(set) var subjectId: String?
    public private(set) var configuration: ConsentIQConfig?
    public private(set) var initializationTask: Task<Void, Never>?

    let storage: ConsentStorage
    let captchaProviderFactory: CaptchaProviderFactory
    let appAttestorFactory: AppAttestorFactory
    let tcfPageFactory: TcfPageFactory
    let tcfKeys = TcfKeyStore()
    var logSink: ((String) -> Void)?
    var logger = ConsentIQLogger()
    var tcfReadyTimeoutNanoseconds = TcfSession.defaultReadyTimeoutNanoseconds
    var tcfAnswerTimeoutNanoseconds = TcfSession.defaultAnswerTimeoutNanoseconds
    var tcfPendingOpen: TcfPendingOpen?
    var tcfFellBack = false
    var tcfSession: TcfSession?
    var tcfTask: Task<Void, Never>?
    var tcfRun = 0
    var hasExistingConsent = false
    var now: () -> Date = Date.init

    private let sessionConfiguration: URLSessionConfiguration
    private var apiClient: ConsentIQAPIClient?
    private var captchaProvider: (any CaptchaTokenProviding)?
    private var hasWarnedAboutCaptcha = false
    // Bumped by resetConsent, so a submit that started before a reset cannot store its 429 after it.
    private var resetGeneration = 0
    // When the server's own record for this person was made, from the last lookup.
    private var serverConsentedAt: Date?

    public nonisolated convenience init(
        storage: ConsentStorage = ConsentStorage(),
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.init(
            storage: storage,
            urlSessionConfiguration: urlSessionConfiguration,
            captchaProviderFactory: { makeDefaultCaptchaProvider(apiURL: $0, propertyKey: $1) }
        )
    }

    nonisolated init(
        storage: ConsentStorage,
        urlSessionConfiguration: URLSessionConfiguration,
        captchaProviderFactory: @escaping CaptchaProviderFactory,
        appAttestorFactory: @escaping AppAttestorFactory = defaultAppAttestorFactory,
        tcfPageFactory: @escaping TcfPageFactory = { makeDefaultTcfPage(pageURL: $0, presenter: $1) }
    ) {
        self.storage = storage
        self.sessionConfiguration = urlSessionConfiguration
        self.captchaProviderFactory = captchaProviderFactory
        self.appAttestorFactory = appAttestorFactory
        self.tcfPageFactory = tcfPageFactory
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
        var client = ConsentIQAPIClient(
            propertyKey: config.propertyKey,
            apiURL: config.apiURL,
            session: URLSession(configuration: sessionConfiguration),
            logger: logger
        )
        client.attestor = appAttestorFactory(client)
        apiClient = client
        isLoading = true
        endTcfSession()
        isTcfActive = false

        do {
            subjectId = resolveSubjectId(config)

            let propertyConfig = try await client.getConfig()
            self.config = propertyConfig
            regulation = propertyConfig.resolvedRegulation
            language = config.language ?? propertyConfig.property.defaultLanguage ?? "en"

            resolveCaptchaProvider(for: propertyConfig, config: config)
            prepareTcf(propertyConfig)

            var foundExistingConsent = false
            if let subjectId {
                foundExistingConsent = await restoreConsent(client: client, subjectId: subjectId)
                if await resendPendingDecision(client: client, subjectId: subjectId) {
                    foundExistingConsent = true
                }
            }
            hasExistingConsent = foundExistingConsent

            isLoading = false

            if isTcfActive {
                if config.autoShow {
                    startTcf(reopen: false)
                }
            } else if config.autoShow, !foundExistingConsent {
                openNativeSheet()
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
        discardTcfDecisionAfterNativeChoice()
        configuration?.onAccept?(ConsentOutcome(scope: .all, consent: accepted))
        await submit(cookieConsents: accepted, marketingConsents: marketingConsent)
    }

    public func rejectAll() async {
        let rejected = ConsentIQ.defaultConsent
        consent = rejected
        isSheetVisible = false
        discardTcfDecisionAfterNativeChoice()
        configuration?.onReject?(ConsentOutcome(consent: rejected))
        await submit(cookieConsents: rejected, marketingConsents: [:])
    }

    public func savePreferences(_ selection: ConsentState) async {
        let next = selection.forcingNecessary()
        consent = next
        isSheetVisible = false
        discardTcfDecisionAfterNativeChoice()
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
        if isTcfActive {
            startTcf(reopen: true)
        } else {
            openNativeSheet()
        }
    }

    public func showPrivacyChoices() {
        showSheet()
    }

    func openNativeSheet() {
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
        resetGeneration += 1
        tcfKeys.clearDecision()
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

        serverConsentedAt = lookup?.consent.flatMap { Self.parseTimestamp($0.consentedAt) }
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
            storage.clearTcf()
            tcfKeys.clearDecision()
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
            if let invalid = InvalidSubjectIdError.check(provided) {
                logger.error(invalid.description)
                config.onError?(invalid)
                return nil
            }
            return provided
        }
        return config.autoGenerateSubjectId ? storage.getOrCreateSubjectId() : nil
    }

    /// `.site` when the subject id in use is the app's own rather than one this SDK generated.
    var subjectSource: SubjectSource? {
        guard let provided = configuration?.subjectId, !provided.isEmpty, provided == subjectId else { return nil }
        return .site
    }

    private func resolveCaptchaProvider(for propertyConfig: PropertyConfig, config: ConsentIQConfig) {
        guard propertyConfig.requireCaptcha else {
            captchaProvider = nil
            return
        }
        captchaProvider = captchaProviderFactory(config.apiURL, config.propertyKey)
        if captchaProvider == nil, !hasWarnedAboutCaptcha {
            hasWarnedAboutCaptcha = true
            logger.warning(ConsentIQLogger.captchaWarning)
        }
    }

    private func captchaToken() async throws -> String? {
        guard let config, config.requiresCaptchaToken, let captchaProvider else { return nil }
        return try await captchaProvider.token()
    }

    // A property without Require CAPTCHA has no provider until the server first asks for one.
    private func challengeProvider() -> (any CaptchaTokenProviding)? {
        if captchaProvider == nil, let configuration {
            captchaProvider = captchaProviderFactory(configuration.apiURL, configuration.propertyKey)
        }
        return captchaProvider
    }

    private func submit(cookieConsents: ConsentState, marketingConsents: MarketingConsentState) async {
        guard let subjectId, let apiClient else {
            logger.debug("Skipping consent submit: no subject id")
            return
        }
        // A new decision replaces any earlier one still waiting to be resent.
        storage.clearPendingDecision()
        let generation = resetGeneration
        let captchaToken: String?
        do {
            captchaToken = try await self.captchaToken()
        } catch {
            logger.debug("Captcha token unavailable: \(error)")
            logger.warning(ConsentIQLogger.captchaFailedWarning)
            return
        }
        let identityToken = configuration?.identityToken
        let subjectSource = subjectSource
        do {
            _ = try await submitAnsweringChallenge(firstToken: captchaToken, provider: challengeProvider) { token in
                try await apiClient.submitConsent(ConsentSubmission(
                    propertyKey: apiClient.propertyKey,
                    subjectId: subjectId,
                    cookieConsents: cookieConsents,
                    marketingConsents: marketingConsents,
                    consentMethod: .sdk,
                    captchaToken: token,
                    identityToken: identityToken,
                    subjectSource: subjectSource
                ))
            }
            storage.clearPendingDecision()
            storage.saveConsent(cookieConsents)
            configuration?.onConsentChange?(cookieConsents, marketingConsents)
        } catch let error as CaptchaError {
            logger.debug("Captcha token unavailable: \(error)")
            logger.warning(ConsentIQLogger.captchaFailedWarning)
        } catch let error as ConsentIQAPIError {
            logger.error("Failed to submit consent: \(error.localizedDescription)")
            handleRefusal(
                error,
                cookieConsents: cookieConsents,
                marketingConsents: marketingConsents,
                subjectId: subjectId,
                generation: generation
            )
        } catch {
            logger.error("Failed to submit consent: \(error.localizedDescription)")
        }
    }

    // 429 keeps the decision for one quiet retry per launch; a refusal resending cannot change drops
    // it; 403 (an identity token that did not verify, or one the property requires) goes to the app.
    private func handleRefusal(
        _ error: ConsentIQAPIError,
        cookieConsents: ConsentState,
        marketingConsents: MarketingConsentState,
        subjectId: String,
        generation: Int
    ) {
        switch error.statusCode {
        case 429 where config?.requiresCaptchaToken != true:
            guard generation == resetGeneration, let configuration else { return }
            storage.savePendingDecision(PendingDecision(
                cookieConsents: cookieConsents,
                marketingConsents: marketingConsents,
                attempts: 0,
                createdAt: now(),
                subjectId: subjectId,
                propertyKey: configuration.propertyKey,
                apiURL: configuration.apiURL.absoluteString
            ))
        case 403:
            storage.clearPendingDecision()
            configuration?.onError?(error)
        default:
            if error.dropsTheDecision {
                storage.clearPendingDecision()
            }
        }
    }

    /// Resends a decision kept after a 429, once per launch and never with a captcha. True when it
    /// was recorded, so the sheet need not ask again.
    private func resendPendingDecision(client: ConsentIQAPIClient, subjectId: String) async -> Bool {
        guard var pending = storage.loadPendingDecision() else { return false }
        let owned = configuration.map {
            pending.belongs(to: subjectId, propertyKey: $0.propertyKey, apiURL: $0.apiURL.absoluteString)
        } ?? false
        // A record the server made after this decision is the newer choice, so it wins.
        let superseded = serverConsentedAt.map { $0 > pending.createdAt } ?? false
        if !owned || superseded || pending.isSpent(at: now()) || config?.requiresCaptchaToken == true {
            storage.clearPendingDecision()
            return false
        }
        pending.attempts += 1
        storage.savePendingDecision(pending)
        do {
            _ = try await client.submitConsent(ConsentSubmission(
                propertyKey: client.propertyKey,
                subjectId: subjectId,
                cookieConsents: pending.cookieConsents,
                marketingConsents: pending.marketingConsents,
                consentMethod: .sdk,
                identityToken: configuration?.identityToken,
                subjectSource: subjectSource
            ))
        } catch let error as ConsentIQAPIError {
            logger.debug("Pending consent not recorded: \(error.localizedDescription)")
            if error.statusCode == 403 {
                storage.clearPendingDecision()
                configuration?.onError?(error)
            } else if error.dropsTheDecision {
                storage.clearPendingDecision()
            }
            return false
        } catch {
            logger.debug("Pending consent not recorded: \(error.localizedDescription)")
            return false
        }
        storage.clearPendingDecision()
        consent = pending.cookieConsents.forcingNecessary()
        marketingConsent = pending.marketingConsents
        storage.saveConsent(consent)
        configuration?.onConsentChange?(consent, marketingConsent)
        return true
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
