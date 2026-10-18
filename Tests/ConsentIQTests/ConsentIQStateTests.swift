import XCTest
@testable import ConsentIQ

@MainActor
final class ConsentIQStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ConsentStorage!
    private var captcha: FakeCaptchaProvider!
    private var logLines: [String] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        suiteName = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ConsentStorage(userDefaults: defaults)
        captcha = FakeCaptchaProvider()
        logLines = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSDK() -> ConsentIQ {
        let sdk = ConsentIQ(
            storage: storage,
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: captcha.factory()
        )
        sdk.logSink = { [weak self] line in self?.logLines.append(line) }
        return sdk
    }

    private func stubConfig(_ json: String = Fixtures.configJSON()) {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: json))
    }

    private func stubConsentLookup(_ json: String, subjectId: String? = nil) {
        if let subjectId {
            StubURLProtocol.stub("GET", Fixtures.consentLookupPath(subjectId), StubResponse(json: json))
        } else {
            StubURLProtocol.stubFallback(StubResponse(json: json))
        }
    }

    private func stubSubmit(status: Int = 200) {
        let json = status == 200 ? Fixtures.submitResultJSON : #"{"error":"Failed to save consent"}"#
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(status: status, json: json))
    }

    private func config(
        autoShow: Bool = true,
        language: String? = nil,
        subjectId: String? = nil,
        autoGenerateSubjectId: Bool = true,
        onConsentChange: ((ConsentState, MarketingConsentState) -> Void)? = nil,
        onOpen: (() -> Void)? = nil,
        onAccept: ((ConsentOutcome) -> Void)? = nil,
        onReject: ((ConsentOutcome) -> Void)? = nil,
        onSave: ((ConsentOutcome) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> ConsentIQConfig {
        ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            subjectId: subjectId,
            autoGenerateSubjectId: autoGenerateSubjectId,
            language: language,
            autoShow: autoShow,
            debug: true,
            onConsentChange: onConsentChange,
            onOpen: onOpen,
            onAccept: onAccept,
            onReject: onReject,
            onSave: onSave,
            onClose: onClose
        )
    }

    // MARK: Init paths

    func testNeverGivenShowsSheetAndFiresOnOpen() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(onOpen: { opened += 1 }))

        XCTAssertFalse(sdk.isLoading)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
        XCTAssertEqual(sdk.regulation, "DPDPA")
        XCTAssertEqual(sdk.language, "en")
        XCTAssertNotNil(sdk.config)
        XCTAssertNil(storage.loadConsent())

        let subjectId = try? XCTUnwrap(sdk.subjectId)
        XCTAssertEqual(subjectId, storage.loadSubjectId())
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Fixtures.configPath, Fixtures.consentLookupPath(subjectId ?? "")])
    }

    func testExistingServerConsentSkipsSheetAndWritesCache() async {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(onOpen: { opened += 1 }))

        XCTAssertFalse(sdk.isLoading)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(sdk.consent["analytics"], true)
        XCTAssertEqual(sdk.consent["marketing"], false)
        XCTAssertEqual(sdk.consent["necessary"], true)
        XCTAssertEqual(sdk.marketingConsent, ["email": true])
        XCTAssertEqual(storage.loadConsent(), sdk.consent)
        XCTAssertTrue(sdk.hasConsent("analytics"))
        XCTAssertFalse(sdk.hasConsent("marketing"))
        XCTAssertTrue(sdk.hasMarketingConsent("email"))
        XCTAssertFalse(sdk.hasMarketingConsent("sms"))
    }

    func testExpiredServerConsentClearsCacheAndShowsSheet() async {
        stubConfig()
        stubConsentLookup(Fixtures.expiredConsentJSON)
        let subjectId = storage.getOrCreateSubjectId()
        storage.saveConsent(["necessary": true, "analytics": true])
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(onOpen: { opened += 1 }))

        XCTAssertNil(storage.loadConsent())
        XCTAssertEqual(storage.loadSubjectId(), subjectId)
        XCTAssertEqual(sdk.subjectId, subjectId)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
    }

    func testLocalCacheSkipsSheetWhenServerHasNothing() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        storage.saveConsent(["necessary": false, "analytics": true, "marketing": false])
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(onOpen: { opened += 1 }))

        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(sdk.consent, ["necessary": true, "analytics": true, "marketing": false])
        XCTAssertFalse(sdk.isLoading)
    }

    func testConsentLookupFailureFallsBackToLocalCache() async {
        stubConfig()
        StubURLProtocol.stubFallback(StubResponse(status: 500, json: #"{"error":"Internal server error"}"#))
        storage.saveConsent(["necessary": true, "analytics": true])
        let sdk = makeSDK()

        await sdk.initialize(config())

        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(sdk.consent["analytics"], true)
        XCTAssertFalse(sdk.isLoading)
    }

    func testConfigFailureLeavesAppUsable() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 404, json: #"{"error":"Property not found"}"#))
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(onOpen: { opened += 1 }))

        XCTAssertFalse(sdk.isLoading)
        XCTAssertNil(sdk.config)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
        XCTAssertTrue(logLines.contains { $0.hasPrefix("[ConsentIQ] Failed to initialize: Property not found") }, "\(logLines)")
    }

    func testAutoShowFalseNeverOpensSheet() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        var opened = 0
        let sdk = makeSDK()

        await sdk.initialize(config(autoShow: false, onOpen: { opened += 1 }))

        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(opened, 0)
        XCTAssertFalse(sdk.isLoading)
    }

    func testConfigureRunsInitAsATask() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        let sdk = makeSDK()

        sdk.configure(config())
        XCTAssertTrue(sdk.isLoading)
        await sdk.initializationTask?.value

        XCTAssertFalse(sdk.isLoading)
        XCTAssertTrue(sdk.isSheetVisible)
    }

    // MARK: Subject id and language

    func testProvidedSubjectIdIsUsedAndNotPersisted() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON, subjectId: "user-42")
        let sdk = makeSDK()

        await sdk.initialize(config(subjectId: "user-42"))

        XCTAssertEqual(sdk.subjectId, "user-42")
        XCTAssertNil(storage.loadSubjectId())
        XCTAssertEqual(StubURLProtocol.requests.last?.path, Fixtures.consentLookupPath("user-42"))
    }

    func testNoSubjectIdWhenAutoGenerationIsOff() async {
        stubConfig()
        stubSubmit()
        let sdk = makeSDK()

        await sdk.initialize(config(autoGenerateSubjectId: false))
        XCTAssertNil(sdk.subjectId)
        XCTAssertEqual(StubURLProtocol.requests.map(\.path), [Fixtures.configPath])
        XCTAssertTrue(sdk.isSheetVisible)

        await sdk.acceptAll()
        XCTAssertEqual(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).count, 0)
        XCTAssertEqual(sdk.consent["analytics"], true)
    }

    func testCallerLanguageWinsOverPropertyDefault() async {
        stubConfig(Fixtures.configJSON(defaultLanguage: "ar"))
        stubConsentLookup(Fixtures.noConsentJSON)
        let sdk = makeSDK()

        await sdk.initialize(config(language: "hi-IN"))

        XCTAssertEqual(sdk.language, "hi-IN")
    }

    func testPropertyDefaultLanguageThenEnglish() async {
        stubConfig(Fixtures.configJSON(defaultLanguage: "ar"))
        stubConsentLookup(Fixtures.noConsentJSON)
        let sdk = makeSDK()
        await sdk.initialize(config())
        XCTAssertEqual(sdk.language, "ar")

        StubURLProtocol.reset()
        stubConfig(Fixtures.configJSON(defaultLanguage: nil))
        stubConsentLookup(Fixtures.noConsentJSON)
        let fallback = makeSDK()
        await fallback.initialize(config())
        XCTAssertEqual(fallback.language, "en")
    }

    func testNullRegulationStaysNil() async {
        stubConfig(Fixtures.configJSON(resolvedRegulation: nil))
        stubConsentLookup(Fixtures.noConsentJSON)
        let sdk = makeSDK()

        await sdk.initialize(config())

        XCTAssertNil(sdk.regulation)
    }

    // MARK: Writes

    func testAcceptAllTurnsOnEveryEnabledCategoryAndPosts() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        stubSubmit()
        var accepted: [ConsentOutcome] = []
        var changes: [(ConsentState, MarketingConsentState)] = []
        var closed = 0
        let sdk = makeSDK()
        await sdk.initialize(config(
            onConsentChange: { changes.append(($0, $1)) },
            onAccept: { accepted.append($0) },
            onClose: { closed += 1 }
        ))

        await sdk.acceptAll()

        let expected: ConsentState = [
            "necessary": true, "analytics": true, "marketing": true, "preferences": false, "social": false, "functional": true,
        ]
        XCTAssertEqual(sdk.consent, expected)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(accepted.first?.scope, .all)
        XCTAssertEqual(accepted.first?.consent, expected)
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, expected)
        XCTAssertEqual(changes.first?.1, [:])
        XCTAssertEqual(storage.loadConsent(), expected)

        let post = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first)
        let body = try XCTUnwrap(post.json)
        XCTAssertEqual(body["propertyKey"] as? String, Fixtures.propertyKey)
        XCTAssertEqual(body["subjectId"] as? String, sdk.subjectId)
        XCTAssertEqual(body["consentMethod"] as? String, "sdk")
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], expected)
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], [:])
        XCTAssertNil(body["subjectType"])
    }

    func testAcceptAllWithoutConfigTurnsOnDefaults() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 500, json: "{}"))
        stubSubmit()
        let sdk = makeSDK()
        await sdk.initialize(config())

        await sdk.acceptAll()

        XCTAssertEqual(sdk.consent, ["necessary": true, "analytics": true, "marketing": true, "preferences": true, "social": true])
    }

    func testRejectAllKeepsOnlyNecessaryAndClearsMarketing() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        stubSubmit()
        var rejected: [ConsentOutcome] = []
        var changes: [(ConsentState, MarketingConsentState)] = []
        let sdk = makeSDK()
        await sdk.initialize(config(onConsentChange: { changes.append(($0, $1)) }, onReject: { rejected.append($0) }))
        XCTAssertEqual(sdk.marketingConsent, ["email": true])
        sdk.showSheet()

        await sdk.rejectAll()

        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(rejected.count, 1)
        XCTAssertNil(rejected.first?.scope)
        XCTAssertEqual(rejected.first?.consent, ConsentIQ.defaultConsent)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.1, [:])

        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first?.json)
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], ConsentIQ.defaultConsent)
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], [:])
        XCTAssertEqual(body["consentMethod"] as? String, "sdk")
    }

    func testSavePreferencesForcesNecessaryAndFiresOnSave() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        stubSubmit()
        var saved: [ConsentOutcome] = []
        var closed = 0
        let sdk = makeSDK()
        await sdk.initialize(config(onSave: { saved.append($0) }, onClose: { closed += 1 }))
        XCTAssertTrue(sdk.isSheetVisible)

        await sdk.savePreferences(["necessary": false, "analytics": true, "marketing": false])

        let expected: ConsentState = ["necessary": true, "analytics": true, "marketing": false]
        XCTAssertEqual(sdk.consent, expected)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.consent, expected)
        XCTAssertNil(saved.first?.scope)
        XCTAssertEqual(closed, 0)
        XCTAssertEqual(storage.loadConsent(), expected)

        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first?.json)
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], expected)
    }

    func testUpdateConsentMergesPartialAndPostsCurrentMarketing() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        stubSubmit()
        let sdk = makeSDK()
        await sdk.initialize(config())

        await sdk.updateConsent(["marketing": true, "necessary": false])

        XCTAssertEqual(sdk.consent, ["necessary": true, "analytics": true, "marketing": true, "preferences": false, "social": false])
        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first?.json)
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], sdk.consent)
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], ["email": true])
    }

    func testUpdateMarketingConsentMergesAndPosts() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        stubSubmit()
        var changes: [(ConsentState, MarketingConsentState)] = []
        let sdk = makeSDK()
        await sdk.initialize(config(onConsentChange: { changes.append(($0, $1)) }))

        await sdk.updateMarketingConsent(["sms": true])

        XCTAssertEqual(sdk.marketingConsent, ["email": true, "sms": true])
        XCTAssertTrue(sdk.hasMarketingConsent("sms"))
        XCTAssertEqual(changes.last?.1, ["email": true, "sms": true])
        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first?.json)
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], ["email": true, "sms": true])
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], sdk.consent)
    }

    func testFailedPostKeepsLocalStateWithoutCacheOrCallback() async {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        stubSubmit(status: 500)
        var changes = 0
        var accepted = 0
        let sdk = makeSDK()
        await sdk.initialize(config(onConsentChange: { _, _ in changes += 1 }, onAccept: { _ in accepted += 1 }))

        await sdk.acceptAll()

        XCTAssertEqual(sdk.consent["analytics"], true)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(storage.loadConsent())
        XCTAssertTrue(logLines.contains { $0.hasPrefix("[ConsentIQ] Failed to submit consent: Failed to save consent") }, "\(logLines)")
    }

    func testNonAsyncWrappersSpawnTheWrite() async throws {
        stubConfig()
        stubConsentLookup(Fixtures.noConsentJSON)
        stubSubmit()
        let sdk = makeSDK()
        await sdk.initialize(config())

        let acceptAllWithoutAwait: () -> Void = sdk.acceptAll
        acceptAllWithoutAwait()

        let deadline = Date().addingTimeInterval(5)
        while StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).count, 1)
        XCTAssertEqual(sdk.consent["analytics"], true)
        XCTAssertFalse(sdk.isSheetVisible)
    }

    // MARK: Sheet lifecycle

    func testShowHideDismissCallbackSemantics() async {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        var opened = 0
        var closed = 0
        let sdk = makeSDK()
        await sdk.initialize(config(onOpen: { opened += 1 }, onClose: { closed += 1 }))
        XCTAssertFalse(sdk.isSheetVisible)

        sdk.showSheet()
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(opened, 1)

        sdk.hideSheet()
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(closed, 0)

        sdk.dismissSheet()
        XCTAssertEqual(closed, 0, "dismissing a hidden sheet is a no-op")

        sdk.showSheet()
        sdk.dismissSheet()
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(closed, 1)
        sdk.dismissSheet()
        XCTAssertEqual(closed, 1, "a second dismiss after the sheet is gone fires nothing")
        XCTAssertEqual(opened, 2)
    }

    func testResetConsentClearsStateAndStorageAndRotatesSubjectId() async {
        stubConfig()
        stubConsentLookup(Fixtures.savedConsentJSON)
        let sdk = makeSDK()
        await sdk.initialize(config())
        let original = sdk.subjectId
        XCTAssertNotNil(storage.loadConsent())

        sdk.resetConsent()

        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
        XCTAssertEqual(sdk.marketingConsent, [:])
        XCTAssertNil(storage.loadConsent())
        XCTAssertNotNil(sdk.subjectId)
        XCTAssertNotEqual(sdk.subjectId, original)
        XCTAssertEqual(storage.loadSubjectId(), sdk.subjectId)
    }
}
