import Foundation

// UserDefaults is thread-safe but predates the Sendable annotations.
public final class ConsentStorage: @unchecked Sendable {
    public static let consentKey = "consentiq_consent"
    public static let subjectIdKey = "consentiq_subject_id"
    public static let tcfKey = "consentiq_tcf"
    public static let pendingKey = "consentiq_pending"

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

    public func clearConsent() {
        defaults.removeObject(forKey: Self.consentKey)
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
    }

    public static func generateSubjectId() -> String {
        UUID().uuidString.lowercased()
    }
}

/// A decision ConsentIQ asked to resend later (429), retried once per launch without a captcha.
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

    func isSpent(at now: Date) -> Bool {
        attempts >= Self.maxAttempts || now.timeIntervalSince(createdAt) > Self.maxAge
    }

    func belongs(to subjectId: String, propertyKey: String, apiURL: String) -> Bool {
        self.subjectId == subjectId && self.propertyKey == propertyKey && self.apiURL == apiURL
    }
}

extension ConsentIQAPIError {
    /// A refusal that resending the same decision cannot change.
    var dropsTheDecision: Bool {
        [400, 404, 409, 422].contains(statusCode)
    }
}
