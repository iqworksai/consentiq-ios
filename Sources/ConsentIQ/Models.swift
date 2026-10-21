import Foundation

public typealias ConsentState = [String: Bool]
public typealias MarketingConsentState = [String: Bool]

public enum ConsentCategory {
    public static let necessary = "necessary"
    public static let analytics = "analytics"
    public static let marketing = "marketing"
    public static let preferences = "preferences"
    public static let social = "social"
}

public enum SubjectType: String, Codable, Sendable {
    case visitor
    case user
    case subscriber
}

public enum ConsentMethod: String, Codable, Sendable {
    case banner
    case preferenceCenter = "preference_center"
    case api
    case sdk
    case form
}

public enum GeoSource: String, Codable, Sendable {
    case ip
    case userOverride = "user_override"
    case browser
}

public struct ConsentOutcome: Sendable {
    public enum Scope: String, Sendable {
        case all
        case required
    }

    public let scope: Scope?
    public let consent: ConsentState

    public init(scope: Scope? = nil, consent: ConsentState) {
        self.scope = scope
        self.consent = consent
    }
}

public struct PropertyInfo: Decodable, Sendable {
    public var id: String
    public var name: String?
    public var identifier: String?
    public var platform: String?
    public var defaultLanguage: String?
    public var supportedLanguages: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, identifier, platform, defaultLanguage, supportedLanguages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        defaultLanguage = try container.decodeIfPresent(String.self, forKey: .defaultLanguage)
        supportedLanguages = try container.decodeIfPresent([String].self, forKey: .supportedLanguages) ?? []
    }
}

public struct BannerConfig: Decodable, Sendable {
    public var position: String?
    public var layout: String?
    public var theme: String?
    public var showLogo: Bool
    public var logoUrl: String?
    public var primaryColor: String?
    public var cornerStyle: String?
    public var showCookieIcon: Bool
    public var cookieIconUrl: String?
    public var overlay: Bool
    public var noticeUrl: String?

    enum CodingKeys: String, CodingKey {
        case position, layout, theme, showLogo, logoUrl, primaryColor, cornerStyle
        case showCookieIcon, cookieIconUrl, overlay, noticeUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        layout = try container.decodeIfPresent(String.self, forKey: .layout)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        showLogo = try container.decodeIfPresent(Bool.self, forKey: .showLogo) ?? false
        logoUrl = try container.decodeIfPresent(String.self, forKey: .logoUrl)
        primaryColor = try container.decodeIfPresent(String.self, forKey: .primaryColor)
        cornerStyle = try container.decodeIfPresent(String.self, forKey: .cornerStyle)
        showCookieIcon = try container.decodeIfPresent(Bool.self, forKey: .showCookieIcon) ?? false
        cookieIconUrl = try container.decodeIfPresent(String.self, forKey: .cookieIconUrl)
        overlay = try container.decodeIfPresent(Bool.self, forKey: .overlay) ?? false
        noticeUrl = try container.decodeIfPresent(String.self, forKey: .noticeUrl)
    }

    public func noticeURL(language: String) -> URL? {
        guard let noticeUrl,
              var components = URLComponents(string: noticeUrl),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "lang", value: language))
        components.queryItems = items
        return components.url
    }
}

public struct CategoryInfo: Decodable, Sendable {
    public var code: String
    public var enabled: Bool
    public var defaultState: Bool
    public var name: String
    public var description: String?
    public var isRequired: Bool

    enum CodingKeys: String, CodingKey {
        case code, enabled, defaultState, name, description, isRequired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        defaultState = try container.decodeIfPresent(Bool.self, forKey: .defaultState) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? code
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    }
}

public struct MarketingChannelInfo: Decodable, Sendable {
    public var code: String
    public var name: String?
    public var description: String?
    public var requiresDoubleOptin: Bool

    enum CodingKeys: String, CodingKey {
        case code, name, description, requiresDoubleOptin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        requiresDoubleOptin = try container.decodeIfPresent(Bool.self, forKey: .requiresDoubleOptin) ?? false
    }
}

public struct GeoRule: Decodable, Sendable {
    public var countries: [String]
    public var regulation: String?
    public var requireExplicitConsent: Bool

    enum CodingKeys: String, CodingKey {
        case countries, regulation, requireExplicitConsent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        countries = try container.decodeIfPresent([String].self, forKey: .countries) ?? []
        regulation = try container.decodeIfPresent(String.self, forKey: .regulation)
        requireExplicitConsent = try container.decodeIfPresent(Bool.self, forKey: .requireExplicitConsent) ?? false
    }
}

public struct PrivacyNoticeInfo: Decodable, Sendable {
    public var id: String
    public var name: String?
    public var noticeType: String?
    public var version: Int?
}

public struct FormConsentSource: Decodable, Sendable {
    public struct Notice: Decodable, Sendable {
        public var id: String
        public var name: String?
        public var type: String?
    }

    public var selector: String?
    public var isAutoResolved: Bool
    public var privacyNotice: Notice?

    enum CodingKeys: String, CodingKey {
        case selector, isAutoResolved, privacyNotice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selector = try container.decodeIfPresent(String.self, forKey: .selector)
        isAutoResolved = try container.decodeIfPresent(Bool.self, forKey: .isAutoResolved) ?? false
        privacyNotice = try container.decodeIfPresent(Notice.self, forKey: .privacyNotice)
    }
}

public struct CategoryTranslation: Decodable, Sendable {
    public var title: String?
    public var description: String?
}

public struct TranslationSet: Decodable, Sendable {
    public var bannerDescription: String?
    public var categories: [String: CategoryTranslation]

    enum CodingKeys: String, CodingKey {
        case bannerDescription, categories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bannerDescription = try container.decodeIfPresent(String.self, forKey: .bannerDescription)
        categories = try container.decodeIfPresent([String: CategoryTranslation].self, forKey: .categories) ?? [:]
    }
}

public struct BannerLabels: Decodable, Sendable, Equatable {
    public var title: String
    public var acceptAll: String
    public var acceptRequired: String
    public var reject: String
    public var customize: String
    public var save: String
    public var preferencesTitle: String
    public var viewNotice: String

    enum CodingKeys: String, CodingKey {
        case title, acceptAll, acceptRequired, reject, customize, save, preferencesTitle, viewNotice
    }

    public init(
        title: String = "",
        acceptAll: String = "",
        acceptRequired: String = "",
        reject: String = "",
        customize: String = "",
        save: String = "",
        preferencesTitle: String = "",
        viewNotice: String = ""
    ) {
        self.title = title
        self.acceptAll = acceptAll
        self.acceptRequired = acceptRequired
        self.reject = reject
        self.customize = customize
        self.save = save
        self.preferencesTitle = preferencesTitle
        self.viewNotice = viewNotice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        acceptAll = try container.decodeIfPresent(String.self, forKey: .acceptAll) ?? ""
        acceptRequired = try container.decodeIfPresent(String.self, forKey: .acceptRequired) ?? ""
        reject = try container.decodeIfPresent(String.self, forKey: .reject) ?? ""
        customize = try container.decodeIfPresent(String.self, forKey: .customize) ?? ""
        save = try container.decodeIfPresent(String.self, forKey: .save) ?? ""
        preferencesTitle = try container.decodeIfPresent(String.self, forKey: .preferencesTitle) ?? ""
        viewNotice = try container.decodeIfPresent(String.self, forKey: .viewNotice) ?? ""
    }
}

public struct PropertyConfig: Decodable, Sendable {
    public var property: PropertyInfo
    public var banner: BannerConfig?
    public var categories: [CategoryInfo]
    public var marketingChannels: [MarketingChannelInfo]
    public var geoRules: [GeoRule]
    public var resolvedRegulation: String?
    public var privacyNotices: [PrivacyNoticeInfo]
    public var formConsentSources: [FormConsentSource]
    public var privacyNoticeUrl: String?
    public var requireCaptcha: Bool
    public var turnstileSiteKey: String?
    public var autoBlock: Bool
    public var tcf: TcfSettings?
    public var translations: [String: TranslationSet]
    public var labels: [String: BannerLabels]
    public var rtl: [String]

    enum CodingKeys: String, CodingKey {
        case property, banner, categories, marketingChannels, geoRules, resolvedRegulation
        case privacyNotices, formConsentSources, privacyNoticeUrl, requireCaptcha, turnstileSiteKey
        case autoBlock, tcf, translations, labels, rtl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        property = try container.decode(PropertyInfo.self, forKey: .property)
        banner = try container.decodeIfPresent(BannerConfig.self, forKey: .banner)
        categories = try container.decodeIfPresent([CategoryInfo].self, forKey: .categories) ?? []
        marketingChannels = try container.decodeIfPresent([MarketingChannelInfo].self, forKey: .marketingChannels) ?? []
        geoRules = try container.decodeIfPresent([GeoRule].self, forKey: .geoRules) ?? []
        resolvedRegulation = try container.decodeIfPresent(String.self, forKey: .resolvedRegulation)
        privacyNotices = try container.decodeIfPresent([PrivacyNoticeInfo].self, forKey: .privacyNotices) ?? []
        formConsentSources = try container.decodeIfPresent([FormConsentSource].self, forKey: .formConsentSources) ?? []
        privacyNoticeUrl = try container.decodeIfPresent(String.self, forKey: .privacyNoticeUrl)
        requireCaptcha = try container.decodeIfPresent(Bool.self, forKey: .requireCaptcha) ?? false
        turnstileSiteKey = try container.decodeIfPresent(String.self, forKey: .turnstileSiteKey)
        autoBlock = try container.decodeIfPresent(Bool.self, forKey: .autoBlock) ?? false
        tcf = try? container.decodeIfPresent(TcfSettings.self, forKey: .tcf)
        translations = try container.decodeIfPresent([String: TranslationSet].self, forKey: .translations) ?? [:]
        labels = try container.decodeIfPresent([String: BannerLabels].self, forKey: .labels) ?? [:]
        rtl = try container.decodeIfPresent([String].self, forKey: .rtl) ?? []
    }

    public func labels(for language: String) -> BannerLabels {
        labels[language]
            ?? labels[Self.baseTag(language)]
            ?? labels["en"]
            ?? labels.values.first
            ?? BannerLabels()
    }

    public func translations(for language: String) -> TranslationSet? {
        translations[language] ?? translations[Self.baseTag(language)] ?? translations["en"]
    }

    public func isRTL(_ language: String) -> Bool {
        rtl.contains(Self.baseTag(language))
    }

    static func baseTag(_ language: String) -> String {
        String(language.split(separator: "-", maxSplits: 1).first ?? Substring(language)).lowercased()
    }
}

public struct SavedConsent: Decodable, Sendable {
    public var id: String
    public var cookieConsents: ConsentState
    public var marketingConsents: MarketingConsentState?
    public var consentedAt: String
    public var expiresAt: String?
    public var regulationApplied: String?
    public var consentVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, cookieConsents, marketingConsents, consentedAt, expiresAt, regulationApplied, consentVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cookieConsents = try container.decodeIfPresent(ConsentState.self, forKey: .cookieConsents) ?? [:]
        marketingConsents = try container.decodeIfPresent(MarketingConsentState.self, forKey: .marketingConsents)
        consentedAt = try container.decodeIfPresent(String.self, forKey: .consentedAt) ?? ""
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        regulationApplied = try container.decodeIfPresent(String.self, forKey: .regulationApplied)
        consentVersion = try container.decodeIfPresent(String.self, forKey: .consentVersion)
    }
}

public struct ConsentLookup: Decodable, Sendable {
    public var consent: SavedConsent?
    public var expired: Bool

    enum CodingKeys: String, CodingKey {
        case consent, expired
    }

    public init(consent: SavedConsent?, expired: Bool) {
        self.consent = consent
        self.expired = expired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consent = try container.decodeIfPresent(SavedConsent.self, forKey: .consent)
        expired = try container.decodeIfPresent(Bool.self, forKey: .expired) ?? false
    }
}

public struct ConsentSubmission: Encodable, Sendable {
    public var propertyKey: String
    public var subjectId: String
    public var subjectType: SubjectType?
    public var cookieConsents: ConsentState?
    public var marketingConsents: MarketingConsentState?
    public var geoCountry: String?
    public var geoRegion: String?
    public var geoSource: GeoSource?
    public var consentMethod: ConsentMethod
    public var consentVersion: String?
    public var captchaToken: String?

    public init(
        propertyKey: String,
        subjectId: String,
        subjectType: SubjectType? = nil,
        cookieConsents: ConsentState? = nil,
        marketingConsents: MarketingConsentState? = nil,
        geoCountry: String? = nil,
        geoRegion: String? = nil,
        geoSource: GeoSource? = nil,
        consentMethod: ConsentMethod = .sdk,
        consentVersion: String? = nil,
        captchaToken: String? = nil
    ) {
        self.propertyKey = propertyKey
        self.subjectId = subjectId
        self.subjectType = subjectType
        self.cookieConsents = cookieConsents
        self.marketingConsents = marketingConsents
        self.geoCountry = geoCountry
        self.geoRegion = geoRegion
        self.geoSource = geoSource
        self.consentMethod = consentMethod
        self.consentVersion = consentVersion
        self.captchaToken = captchaToken
    }
}

public struct ConsentSubmissionResult: Decodable, Sendable {
    public var success: Bool
    public var consentId: String
    public var proofHash: String

    enum CodingKeys: String, CodingKey {
        case success, consentId, proofHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        consentId = try container.decodeIfPresent(String.self, forKey: .consentId) ?? ""
        proofHash = try container.decodeIfPresent(String.self, forKey: .proofHash) ?? ""
    }
}

public struct ConsentVerification: Decodable, Sendable {
    public struct Record: Decodable, Sendable {
        public var id: String
        public var consentedAt: String?
        public var proofHash: String?
    }

    public var verified: Bool
    public var consent: Record?

    enum CodingKeys: String, CodingKey {
        case verified, consent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        consent = try container.decodeIfPresent(Record.self, forKey: .consent)
    }
}

extension Dictionary where Key == String, Value == Bool {
    func forcingNecessary() -> [String: Bool] {
        var copy = self
        copy[ConsentCategory.necessary] = true
        return copy
    }
}
