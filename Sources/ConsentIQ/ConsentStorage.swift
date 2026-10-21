import Foundation

// UserDefaults is thread-safe but predates the Sendable annotations.
public final class ConsentStorage: @unchecked Sendable {
    public static let consentKey = "consentiq_consent"
    public static let subjectIdKey = "consentiq_subject_id"
    public static let tcfKey = "consentiq_tcf"

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

    public func clearAll() {
        clearConsent()
        clearSubjectId()
        clearTcf()
    }

    public static func generateSubjectId() -> String {
        UUID().uuidString.lowercased()
    }
}
