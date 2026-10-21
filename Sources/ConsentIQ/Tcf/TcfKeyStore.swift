import Foundation

// IAB's in-app spec has vendor SDKs read UserDefaults.standard, so these keys never go to the injectable store.
struct TcfKeyStore {
    static let prefix = "IABTCF_"
    static let cmpSdkIdKey = "IABTCF_CmpSdkID"
    static let cmpSdkVersionKey = "IABTCF_CmpSdkVersion"
    static let gdprAppliesKey = "IABTCF_gdprApplies"
    static let publisherRestrictionKeys = (1...11).map { "IABTCF_PublisherRestrictions\($0)" }
    static let writtenCmpIdKey = "consentiq_tcf_cmp_id"
    static let decisionKeys = [
        "IABTCF_TCString", "IABTCF_VendorConsents", "IABTCF_VendorLegitimateInterests", "IABTCF_DisclosedVendors",
        "IABTCF_PurposeConsents", "IABTCF_PurposeLegitimateInterests", "IABTCF_SpecialFeaturesOptIns",
        "IABTCF_PublisherConsent", "IABTCF_PublisherLegitimateInterests", "IABTCF_PublisherCustomPurposesConsents",
        "IABTCF_PublisherCustomPurposesLegitimateInterests", "IABTCF_PolicyVersion", "IABTCF_PublisherCC",
        "IABTCF_PurposeOneTreatment", "IABTCF_UseNonStandardTexts",
    ] + publisherRestrictionKeys
    static let cmpKeys: Set<String> = [cmpSdkIdKey, cmpSdkVersionKey]

    private var defaults: UserDefaults { .standard }

    var isOurs: Bool {
        guard let written = defaults.object(forKey: Self.writtenCmpIdKey) as? Int else { return false }
        return defaults.object(forKey: Self.cmpSdkIdKey) as? Int == written
    }

    func write(keys: [String: Any]) {
        var written = Set<String>()
        for (key, value) in keys where key.hasPrefix(Self.prefix) && !Self.cmpKeys.contains(key) {
            if let string = value as? String {
                defaults.set(string, forKey: key)
            } else if let number = value as? NSNumber {
                defaults.set(number.intValue, forKey: key)
            } else {
                continue
            }
            written.insert(key)
        }
        for key in Self.publisherRestrictionKeys where !written.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }

    func writeGdprApplies(_ value: Int) {
        guard isOurs else { return }
        defaults.set(value, forKey: Self.gdprAppliesKey)
    }

    // CMP IDs are unique, so a stored ID equal to ours can only have been written by this SDK.
    @discardableResult
    func claimCmp(id: Int, version: Int?) -> Bool {
        let existing = defaults.object(forKey: Self.cmpSdkIdKey) as? Int
        guard existing == nil || existing == id || isOurs else { return false }
        takeOverCmp(id: id, version: version)
        return true
    }

    // Only for a decision the visitor made in ConsentIQ's own screens, which makes ConsentIQ the CMP.
    func takeOverCmp(id: Int, version: Int?) {
        defaults.set(id, forKey: Self.cmpSdkIdKey)
        defaults.set(id, forKey: Self.writtenCmpIdKey)
        if let version {
            defaults.set(version, forKey: Self.cmpSdkVersionKey)
        }
    }

    func clearDecision() {
        guard isOurs else { return }
        for key in Self.decisionKeys {
            defaults.removeObject(forKey: key)
        }
    }

    func clearAll() {
        guard isOurs else { return }
        for key in Self.decisionKeys + [Self.cmpSdkIdKey, Self.cmpSdkVersionKey, Self.gdprAppliesKey, Self.writtenCmpIdKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
