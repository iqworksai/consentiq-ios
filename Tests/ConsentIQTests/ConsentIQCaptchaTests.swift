import XCTest
@testable import ConsentIQ

@MainActor
final class ConsentIQCaptchaTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ConsentStorage!
    private var captcha: FakeCaptchaProvider!
    private var logLines: [String] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
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

    private func makeSDK(captchaAvailable: Bool = true) -> ConsentIQ {
        let sdk = ConsentIQ(
            storage: storage,
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: captcha.factory(available: captchaAvailable)
        )
        sdk.logSink = { [weak self] line in self?.logLines.append(line) }
        return sdk
    }

    private func stubConfig(_ json: String) {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: json))
    }

    private func config(
        onConsentChange: ((ConsentState, MarketingConsentState) -> Void)? = nil,
        onAccept: ((ConsentOutcome) -> Void)? = nil
    ) -> ConsentIQConfig {
        ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            debug: true,
            onConsentChange: onConsentChange,
            onAccept: onAccept
        )
    }

    private var posts: [RecordedRequest] {
        StubURLProtocol.requests(matching: "POST", Fixtures.consentPath)
    }

    func testSendsAFreshTokenOnEverySubmitAndNoneAtStartup() async {
        stubConfig(Fixtures.captchaConfigJSON)
        let sdk = makeSDK()

        await sdk.initialize(config())
        XCTAssertEqual(captcha.requestedAPIURLs, [Fixtures.apiURL])
        XCTAssertEqual(captcha.tokenCount, 0)

        await sdk.acceptAll()
        await sdk.rejectAll()
        await sdk.savePreferences(["analytics": true])
        await sdk.updateConsent(["marketing": true])
        await sdk.updateMarketingConsent(["email": true])

        XCTAssertEqual(posts.count, 5)
        XCTAssertEqual(posts.map { $0.json?["captchaToken"] as? String }, Array(repeating: "tok", count: 5))
        XCTAssertEqual(captcha.tokenCount, 5)
        XCTAssertFalse(logLines.contains { $0.localizedCaseInsensitiveContains("captcha") }, "\(logLines)")
    }

    func testFailureSendsNothingAndKeepsLocalState() async throws {
        stubConfig(Fixtures.captchaConfigJSON)
        captcha.result = .failure(CaptchaError.timedOut)
        var changes = 0
        var accepted = 0
        let sdk = makeSDK()
        await sdk.initialize(config(onConsentChange: { _, _ in changes += 1 }, onAccept: { _ in accepted += 1 }))

        await sdk.acceptAll()

        XCTAssertEqual(captcha.tokenCount, 1)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(sdk.consent["analytics"], true)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(changes, 0)
        XCTAssertNil(storage.loadConsent())
        XCTAssertEqual(logLines.filter { $0 == "[ConsentIQ] Captcha check failed; consent not submitted" }.count, 1, "\(logLines)")
        let subjectId = try XCTUnwrap(sdk.subjectId)
        XCTAssertFalse(logLines.contains { $0.contains(subjectId) }, "\(logLines)")
    }

    func testNotRequiredNeverAsksForAToken() async throws {
        stubConfig(Fixtures.configJSON())
        let sdk = makeSDK()

        await sdk.initialize(config())
        await sdk.acceptAll()

        XCTAssertEqual(captcha.requestedAPIURLs, [])
        XCTAssertEqual(captcha.tokenCount, 0)
        let body = try XCTUnwrap(posts.first?.json)
        XCTAssertNil(body["captchaToken"])
        XCTAssertFalse(logLines.contains { $0.localizedCaseInsensitiveContains("captcha") }, "\(logLines)")
    }

    func testRequiredWithoutASiteKeySubmitsWithoutAToken() async throws {
        stubConfig(Fixtures.configJSON(requireCaptcha: true, turnstileSiteKey: nil))
        let sdk = makeSDK()

        await sdk.initialize(config())
        await sdk.acceptAll()

        XCTAssertEqual(captcha.tokenCount, 0)
        let body = try XCTUnwrap(posts.first?.json)
        XCTAssertNil(body["captchaToken"])
    }

    func testWithoutAProviderWarnsOnceAndSubmitsWithoutAToken() async {
        stubConfig(Fixtures.captchaConfigJSON)
        let sdk = makeSDK(captchaAvailable: false)

        await sdk.initialize(config())
        await sdk.acceptAll()
        await sdk.rejectAll()

        let expected = "[ConsentIQ] This property requires a captcha, which mobile SDKs cannot satisfy. "
            + "Turn off \"Require captcha\" for this property in the ConsentIQ dashboard."
        XCTAssertEqual(logLines.filter { $0 == expected }.count, 1, "\(logLines)")
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts.allSatisfy { $0.json?["captchaToken"] == nil })
        XCTAssertEqual(captcha.tokenCount, 0)
    }
}
