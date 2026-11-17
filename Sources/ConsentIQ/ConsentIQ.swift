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
                // A decision dropped unrecorded leaves nothing granted: neither an older server record nor
                // the local copy answers for it, so the sheet asks again.
                if !storage.isUnrecorded(propertyKey: config.propertyKey) {
                    foundExistingConsent = await restoreConsent(client: client, subjectId: subjectId)
                }
                switch await resendPendingDecision(client: client, subjectId: subjectId) {
                case .recorded: foundExistingConsent = true
                case .dropped: foundExistingConsent = false
                case .none: break
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
        // An id the app chose is read only with its identity token; without one the local copy stands,
        // since the open lookup reads only ids this SDK generated.
        let siteSubject = subjectSource != nil
        let identityToken = configuration?.identityToken
        let lookup: ConsentLookup?
        if siteSubject && identityToken == nil {
            lookup = nil
        } else {
            do {
                lookup = try await client.getConsent(subjectId: subjectId, identityToken: siteSubject ? identityToken : nil)
            } catch let error as ConsentIQAPIError where error.statusCode == 403 {
                // The token did not verify for this subject, so this device's copy cannot answer for them:
                // the sheet asks again, and the app is told.
                logger.error("Consent lookup refused: \(error.localizedDescription)")
                storage.clearConsent()
                configuration?.onError?(error)
                return false
            } catch {
                logger.debug("Consent lookup failed: \(error.localizedDescription)")
                lookup = nil
            }
        }

        serverConsentedAt = lookup?.consent.flatMap { Self.parseTimestamp($0.consentedAt) }
        if let saved = lookup?.consent {
            consent = saved.cookieConsents.forcingNecessary()
            if let marketing = saved.marketingConsents {
                marketingConsent = marketing
            }
            storage.saveConsent(consent, for: subjectId)
            return true
        }
        if lookup?.expired == true {
            storage.clearConsent()
            storage.clearTcf()
            tcfKeys.clearDecision()
            return false
        }
        if let local = storage.loadConsent(for: subjectId) {
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

    /// The identity token, only where it can verify: with the app's own subject id. A generated id is
    /// random, so a token signed for the app's user never matches it.
    var identityTokenForSubject: String? {
        subjectSource == .site ? configuration?.identityToken : nil
    }

    private var noticeVersion: Int? { config?.banner?.noticeVersion }
    private var categoryCodes: [String] { (config?.categories ?? []).map(\.code).sorted() }

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
        // The decision applies at once and stands locally; the server record makes it stand across launches.
        storage.saveConsent(cookieConsents, for: subjectId)
        let generation = resetGeneration
        let decision = UnrecordedDecision(
            cookieConsents: cookieConsents,
            marketingConsents: marketingConsents,
            subjectId: subjectId,
            generation: generation
        )
        let captchaToken: String?
        do {
            captchaToken = try await self.captchaToken()
        } catch {
            logger.debug("Captcha token unavailable: \(error)")
            logger.warning(ConsentIQLogger.captchaFailedWarning)
            settleFailure(error, status: nil, decision: decision)
            return
        }
        let identityToken = identityTokenForSubject
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
            guard generation == resetGeneration else { return }
            storage.clearPendingDecision()
            storage.clearUnrecorded()
            configuration?.onConsentChange?(cookieConsents, marketingConsents)
        } catch let error as CaptchaError {
            logger.debug("Captcha token unavailable: \(error)")
            logger.warning(ConsentIQLogger.captchaFailedWarning)
            settleFailure(error, status: nil, decision: decision)
        } catch let error as ConsentIQAPIError {
            logger.error("Failed to submit consent: \(error.localizedDescription)")
            settleFailure(error, status: error.statusCode, decision: decision)
        } catch {
            logger.error("Failed to submit consent: \(error.localizedDescription)")
            settleFailure(error, status: nil, decision: decision)
        }
    }

    /// A submit ConsentIQ did not record. Retryable (no answer, a 5xx, a 429, an unanswered challenge)
    /// keeps it as the pending decision, replacing any earlier one. Anything else, or any failure on a
    /// property that requires a captcha on every submit (a resend cannot carry one), is final: the
    /// decision and its local copy are dropped, the next launch asks again, and the app is told.
    private func settleFailure(_ error: Error, status: Int?, decision: UnrecordedDecision) {
        // A submit that started before a reset belongs to the state the reset cleared.
        guard decision.generation == resetGeneration, let configuration else { return }
        let final = status.map(ConsentIQAPIError.isFinal) ?? false
        if final || config?.requiresCaptchaToken == true {
            dropUnrecordedDecision(propertyKey: configuration.propertyKey)
            configuration.onError?(error)
            return
        }
        storage.savePendingDecision(PendingDecision(
            cookieConsents: decision.cookieConsents,
            marketingConsents: decision.marketingConsents,
            attempts: 0,
            createdAt: now(),
            subjectId: decision.subjectId,
            propertyKey: configuration.propertyKey,
            apiURL: configuration.apiURL.absoluteString,
            noticeVersion: noticeVersion,
            categoryCodes: categoryCodes
        ))
    }

    /// The decision was never recorded and never will be: its local copy goes with it, and the next
    /// launch asks again with nothing granted rather than restoring an older choice.
    private func dropUnrecordedDecision(propertyKey: String) {
        storage.clearPendingDecision()
        storage.clearConsent()
        storage.markUnrecorded(propertyKey: propertyKey)
    }

    private enum ResendOutcome { case none, recorded, dropped }

    private struct UnrecordedDecision {
        let cookieConsents: ConsentState
        let marketingConsents: MarketingConsentState
        let subjectId: String
        let generation: Int
    }

    /// Resends a decision ConsentIQ has not recorded, once per launch and never with a captcha. Recorded
    /// means the sheet need not ask again; dropped means it must, with nothing granted.
    private func resendPendingDecision(client: ConsentIQAPIClient, subjectId: String) async -> ResendOutcome {
        guard var pending = storage.loadPendingDecision(), let configuration else { return .none }
        guard pending.belongs(to: subjectId, propertyKey: configuration.propertyKey, apiURL: configuration.apiURL.absoluteString) else {
            // Another person's, property's or server's: never sent here.
            storage.clearPendingDecision()
            return .none
        }
        // A record the server made after this decision is the newer choice, so it wins.
        if let serverConsentedAt, serverConsentedAt > pending.createdAt {
            storage.clearPendingDecision()
            return .none
        }
        if pending.isSpent(at: now())
            || !pending.matches(noticeVersion: noticeVersion, categoryCodes: categoryCodes)
            || config?.requiresCaptchaToken == true {
            return dropAtLaunch(propertyKey: configuration.propertyKey)
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
                identityToken: identityTokenForSubject,
                subjectSource: subjectSource,
                noticeVersion: pending.noticeVersion
            ))
        } catch let error as ConsentIQAPIError {
            logger.debug("Pending consent not recorded: \(error.localizedDescription)")
            if ConsentIQAPIError.isFinal(error.statusCode) {
                configuration.onError?(error)
                return dropAtLaunch(propertyKey: configuration.propertyKey)
            }
            return .none
        } catch {
            logger.debug("Pending consent not recorded: \(error.localizedDescription)")
            return .none
        }
        storage.clearPendingDecision()
        storage.clearUnrecorded()
        consent = pending.cookieConsents.forcingNecessary()
        marketingConsent = pending.marketingConsents
        storage.saveConsent(consent, for: subjectId)
        configuration.onConsentChange?(consent, marketingConsent)
        return .recorded
    }

    /// At launch the dropped decision's local copy may already be applied, so it is taken back too.
    private func dropAtLaunch(propertyKey: String) -> ResendOutcome {
        dropUnrecordedDecision(propertyKey: propertyKey)
        consent = ConsentIQ.defaultConsent
        marketingConsent = [:]
        return .dropped
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
