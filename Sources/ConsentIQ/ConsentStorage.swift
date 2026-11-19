import Foundation

// UserDefaults is thread-safe but predates the Sendable annotations.
public final class ConsentStorage: @unchecked Sendable {
    public static let consentKey = "consentiq_consent"
    public static let subjectIdKey = "consentiq_subject_id"
    public static let tcfKey = "consentiq_tcf"
    public static let pendingKey = "consentiq_pending"
    /// The subject the local copy was written for; a copy written for another subject is not theirs.
    public static let consentSubjectKey = "consentiq_consent_subject"
    /// Set to the property key when a decision was dropped without ConsentIQ recording it. While it
    /// stands the sheet asks again with nothing granted. The next recorded decision clears it.
    public static let unrecordedKey = "consentiq_unrecorded_decision"

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    public func loadConsent() -> ConsentState? {
        guard let data = defaults.data(forKey: Self.consentKey) else { return nil }
        return try? JSONDecoder().decode(ConsentState.self, from: data)
    }

    public func saveConsent(_ consent: ConsentState) {
        guard let data = try? JSONEncoder().encode(consent) else { return }
        defaults.set(data, forKey: Self.consentKey)
    }

    /// The local copy, only when it was written for this subject.
    public func loadConsent(for subjectId: String) -> ConsentState? {
        guard defaults.string(forKey: Self.consentSubjectKey) == subjectId else { return nil }
        return loadConsent()
    }

    public func saveConsent(_ consent: ConsentState, for subjectId: String) {
        saveConsent(consent)
        defaults.set(subjectId, forKey: Self.consentSubjectKey)
    }

    public func clearConsent() {
        defaults.removeObject(forKey: Self.consentKey)
        defaults.removeObject(forKey: Self.consentSubjectKey)
    }

    func isUnrecorded(propertyKey: String) -> Bool {
        defaults.string(forKey: Self.unrecordedKey) == propertyKey
    }

    func markUnrecorded(propertyKey: String) {
        defaults.set(propertyKey, forKey: Self.unrecordedKey)
    }

    func clearUnrecorded() {
        defaults.removeObject(forKey: Self.unrecordedKey)
    }

    public func loadSubjectId() -> String? {
        defaults.string(forKey: Self.subjectIdKey)
    }

    public func getOrCreateSubjectId() -> String {
        if let existing = loadSubjectId(), !existing.isEmpty {
            return existing
        }
        let created = Self.generateSubjectId()
        defaults.set(created, forKey: Self.subjectIdKey)
        return created
    }

    public func clearSubjectId() {
        defaults.removeObject(forKey: Self.subjectIdKey)
    }

    func loadTcfStored() -> [String: Any]? {
        guard let data = defaults.data(forKey: Self.tcfKey) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func saveTcfStored(_ stored: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(stored),
              let data = try? JSONSerialization.data(withJSONObject: stored) else { return }
        defaults.set(data, forKey: Self.tcfKey)
    }

    public func clearTcf() {
        defaults.removeObject(forKey: Self.tcfKey)
    }

    func loadPendingDecision() -> PendingDecision? {
        guard let data = defaults.data(forKey: Self.pendingKey) else { return nil }
        guard let pending = try? JSONDecoder().decode(PendingDecision.self, from: data) else {
            clearPendingDecision()
            return nil
        }
        return pending
    }

    func savePendingDecision(_ pending: PendingDecision) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        defaults.set(data, forKey: Self.pendingKey)
    }

    func clearPendingDecision() {
        defaults.removeObject(forKey: Self.pendingKey)
    }

    public func clearAll() {
        clearConsent()
        clearSubjectId()
        clearTcf()
        clearPendingDecision()
        clearUnrecorded()
    }

    public static func generateSubjectId() -> String {
        UUID().uuidString.lowercased()
    }
}

/// A decision ConsentIQ has not recorded yet (no answer, a 5xx, a 429, an unanswered challenge), resent
/// once per launch without a captcha.
struct PendingDecision: Codable, Equatable {
    static let maxAttempts = 3
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    var cookieConsents: ConsentState
    var marketingConsents: MarketingConsentState
    var attempts: Int
    var createdAt: Date
    // Whose decision it is and where it goes: resent only to the same person, property and server.
    var subjectId: String
    var propertyKey: String
    var apiURL: String
    // What it was decided against: one made under another notice or category set is never resent.
    var noticeVersion: Int?
    var categoryCodes: [String]?

    func isSpent(at now: Date) -> Bool {
        attempts >= Self.maxAttempts || now.timeIntervalSince(createdAt) > Self.maxAge
    }

    func belongs(to subjectId: String, propertyKey: String, apiURL: String) -> Bool {
        self.subjectId == subjectId && self.propertyKey == propertyKey && self.apiURL == apiURL
    }

    func matches(noticeVersion: Int?, categoryCodes: [String]) -> Bool {
        self.noticeVersion == noticeVersion && (self.categoryCodes ?? []) == categoryCodes
    }
}

extension ConsentIQAPIError {
    /// A refusal that resending the same decision cannot change: 400, 403, 404, 409, 422. No answer, a
    /// 5xx, a 429 or a challenge left unanswered may go through later.
    static func isFinal(_ statusCode: Int) -> Bool {
        [400, 403, 404, 409, 422].contains(statusCode)
    }
}
