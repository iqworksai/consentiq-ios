import Foundation

public struct ConsentIQConfig {
    public static let defaultAPIURL = ConsentIQAPIClient.defaultAPIURL

    public var propertyKey: String
    public var apiURL: URL
    public var subjectId: String?
    public var autoGenerateSubjectId: Bool
    public var language: String?
    public var autoShow: Bool
    public var debug: Bool
    public var onConsentChange: ((ConsentState, MarketingConsentState) -> Void)?
    public var onOpen: (() -> Void)?
    public var onAccept: ((ConsentOutcome) -> Void)?
    public var onReject: ((ConsentOutcome) -> Void)?
    public var onSave: ((ConsentOutcome) -> Void)?
    public var onClose: (() -> Void)?

    public init(
        propertyKey: String,
        apiURL: URL = ConsentIQConfig.defaultAPIURL,
        subjectId: String? = nil,
        autoGenerateSubjectId: Bool = true,
        language: String? = nil,
        autoShow: Bool = true,
        debug: Bool = false,
        onConsentChange: ((ConsentState, MarketingConsentState) -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        onAccept: ((ConsentOutcome) -> Void)? = nil,
        onReject: ((ConsentOutcome) -> Void)? = nil,
        onSave: ((ConsentOutcome) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.propertyKey = propertyKey
        self.apiURL = apiURL
        self.subjectId = subjectId
        self.autoGenerateSubjectId = autoGenerateSubjectId
        self.language = language
        self.autoShow = autoShow
        self.debug = debug
        self.onConsentChange = onConsentChange
        self.onOpen = onOpen
        self.onAccept = onAccept
        self.onReject = onReject
        self.onSave = onSave
        self.onClose = onClose
    }
}
