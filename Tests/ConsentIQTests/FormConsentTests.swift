import XCTest
@testable import ConsentIQ

@MainActor
final class FormConsentTests: XCTestCase {
    private var captcha: FakeCaptchaProvider!
    private var logLines: [String] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))
        captcha = FakeCaptchaProvider()
        logLines = []
    }

    private func makeForm(
        subjectId: String = "user-1",
        channels: [String] = FormConsent.defaultChannels,
        consentIQ: ConsentIQ? = nil,
        onSubmitted: ((FormConsentResult) -> Void)? = nil,
        onChange: ((MarketingConsentState) -> Void)? = nil
    ) -> FormConsent {
        FormConsent(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            subjectId: subjectId,
            subjectType: .user,
            channels: channels,
            session: URLSession(configuration: StubURLProtocol.sessionConfiguration),
            debug: true,
            onConsentSubmitted: onSubmitted,
            onConsentChange: onChange,
            consentIQ: consentIQ,
            captchaProviderFactory: captcha.factory(),
            logSink: { [weak self] line in self?.logLines.append(line) }
        )
    }

    private func stubSubmit() {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
    }

    private var posts: [RecordedRequest] {
        StubURLProtocol.requests(matching: "POST", Fixtures.consentPath)
    }

    private var configFetches: Int {
        StubURLProtocol.requests(matching: "GET", Fixtures.configPath).count
    }

    func testDefaultsToFourChannelsOff() {
        let form = makeForm()
        XCTAssertEqual(form.consents, ["email": false, "sms": false, "whatsapp": false, "push": false])
        XCTAssertFalse(form.isSubmitting)
    }

    func testToggleAndSetReportChanges() {
        var reported: [MarketingConsentState] = []
        let form = makeForm(onChange: { reported.append($0) })

        form.toggle("email")
        form.set("sms", true)
        form.toggle("email")

        XCTAssertEqual(form.consents, ["email": false, "sms": true, "whatsapp": false, "push": false])
        XCTAssertEqual(reported.count, 3)
        XCTAssertEqual(reported[0]["email"], true)
        XCTAssertEqual(reported[2]["email"], false)
    }

    func testSubmitPostsMarketingConsentsAsUserFormConsent() async throws {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
        var submitted: [FormConsentResult] = []
        let form = makeForm(onSubmitted: { submitted.append($0) })
        form.set("email", true)

        let result = await form.submit()

        XCTAssertEqual(result?.consentId, "c-2")
        XCTAssertEqual(result?.proofHash, "abc123")
        XCTAssertEqual(result?.consents["email"], true)
        XCTAssertEqual(submitted.count, 1)
        XCTAssertFalse(form.isSubmitting)

        let body = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first?.json)
        XCTAssertEqual(body["propertyKey"] as? String, Fixtures.propertyKey)
        XCTAssertEqual(body["subjectId"] as? String, "user-1")
        XCTAssertEqual(body["subjectType"] as? String, "user")
        XCTAssertEqual(body["consentMethod"] as? String, "form")
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], ["email": true, "sms": false, "whatsapp": false, "push": false])
        XCTAssertNil(body["cookieConsents"])
    }

    func testSubmitWithoutSubjectIdDoesNothing() async {
        let form = makeForm(subjectId: "")

        let result = await form.submit()

        XCTAssertNil(result)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testSubmitFailureReturnsNil() async throws {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.captchaConfigJSON))
        let refused = StubResponse(status: 400, json: #"{"error":"Captcha verification failed. Please try again."}"#)
        StubURLProtocol.stub("POST", Fixtures.consentPath, refused)
        var submitted = 0
        let form = makeForm(onSubmitted: { _ in submitted += 1 })

        let result = await form.submit()

        XCTAssertNil(result)
        XCTAssertEqual(submitted, 0)
        XCTAssertFalse(form.isSubmitting)
        let body = try XCTUnwrap(posts.first?.json)
        XCTAssertEqual(body["captchaToken"] as? String, "tok")
    }

    func testCaptchaTokenIsSentAndConfigIsFetchedOnce() async throws {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.captchaConfigJSON))
        stubSubmit()
        let form = makeForm()

        let first = await form.submit()
        let second = await form.submit()

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(configFetches, 1)
        XCTAssertEqual(captcha.requestedAPIURLs, [Fixtures.apiURL])
        XCTAssertEqual(captcha.tokenCount, 2)
        XCTAssertEqual(posts.map { $0.json?["captchaToken"] as? String }, ["tok", "tok"])
    }

    func testCaptchaFailureReturnsNilAndPostsNothing() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.captchaConfigJSON))
        stubSubmit()
        captcha.result = .failure(CaptchaError.challengeFailed(code: "600010"))
        var submitted = 0
        let form = makeForm(onSubmitted: { _ in submitted += 1 })

        let result = await form.submit()

        XCTAssertNil(result)
        XCTAssertEqual(submitted, 0)
        XCTAssertFalse(form.isSubmitting)
        XCTAssertEqual(captcha.tokenCount, 1)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(logLines.filter { $0 == "[ConsentIQ] Captcha check failed; consent not submitted" }.count, 1, "\(logLines)")
        XCTAssertFalse(logLines.contains { $0.contains("user-1") }, "\(logLines)")
    }

    func testCaptchaNotRequiredNeverAsksForAToken() async throws {
        stubSubmit()
        let form = makeForm()

        let result = await form.submit()

        XCTAssertNotNil(result)
        XCTAssertEqual(captcha.tokenCount, 0)
        let body = try XCTUnwrap(posts.first?.json)
        XCTAssertNil(body["captchaToken"])
    }

    func testConfigFetchFailureSubmitsWithoutAToken() async throws {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 500, json: "{}"))
        stubSubmit()
        let form = makeForm()

        let result = await form.submit()

        XCTAssertNotNil(result)
        XCTAssertEqual(captcha.tokenCount, 0)
        let body = try XCTUnwrap(posts.first?.json)
        XCTAssertNil(body["captchaToken"])
    }

    func testReusesTheLoadedSDKConfigForTheSameProperty() async throws {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.captchaConfigJSON))
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        stubSubmit()
        let suite = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sdk = ConsentIQ(
            storage: ConsentStorage(userDefaults: defaults),
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: captcha.factory()
        )
        await sdk.initialize(ConsentIQConfig(propertyKey: Fixtures.propertyKey, apiURL: Fixtures.apiURL, autoShow: false))
        XCTAssertEqual(configFetches, 1)

        let result = await makeForm(consentIQ: sdk).submit()

        XCTAssertNotNil(result)
        XCTAssertEqual(configFetches, 1)
        XCTAssertEqual(posts.first?.json?["captchaToken"] as? String, "tok")
    }

    func testResetClearsEveryChannel() {
        let form = makeForm(channels: ["email", "push"])
        form.set("email", true)
        form.set("push", true)

        form.reset()

        XCTAssertEqual(form.consents, ["email": false, "push": false])
    }

    func testConvenienceInitBorrowsSDKConfiguration() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        let suite = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sdk = ConsentIQ(storage: ConsentStorage(userDefaults: defaults), urlSessionConfiguration: StubURLProtocol.sessionConfiguration)
        await sdk.initialize(ConsentIQConfig(propertyKey: Fixtures.propertyKey, apiURL: Fixtures.apiURL))

        let form = FormConsent(consentIQ: sdk)

        XCTAssertEqual(form.subjectId, sdk.subjectId)
        XCTAssertEqual(form.subjectType, .user)
    }
}
