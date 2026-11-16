import XCTest
@testable import ConsentIQ

@MainActor
final class PendingDecisionTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ConsentStorage!
    private var captcha: FakeCaptchaProvider!
    private var errors: [Error] = []
    private var changes = 0

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))
        suiteName = "ai.iqworks.consentiq.pending.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ConsentStorage(userDefaults: defaults)
        captcha = FakeCaptchaProvider()
        errors = []
        changes = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func refuse(_ status: Int, _ message: String = "refused") {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(status: status, json: #"{"error":"\#(message)"}"#))
    }

    private func accept() {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
    }

    private var posts: [RecordedRequest] {
        StubURLProtocol.requests(matching: "POST", Fixtures.consentPath)
    }

    private func launch(at date: Date = Date()) async -> ConsentIQ {
        let sdk = ConsentIQ(
            storage: storage,
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: captcha.factory(),
            appAttestorFactory: { _ in nil }
        )
        sdk.now = { date }
        await sdk.initialize(ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            autoShow: false,
            onConsentChange: { [weak self] _, _ in self?.changes += 1 },
            onError: { [weak self] in self?.errors.append($0) }
        ))
        return sdk
    }

    func testATooManyRequestsAnswerKeepsTheDecisionAndTheNextLaunchSendsItWithoutACaptcha() async throws {
        refuse(429, "Too many requests")
        let first = await launch()
        await first.acceptAll()
        XCTAssertNotNil(storage.loadPendingDecision())
        XCTAssertEqual(changes, 0)

        accept()
        let second = await launch()

        XCTAssertEqual(posts.count, 2)
        XCTAssertNil(posts[1].json?["captchaToken"])
        XCTAssertEqual((posts[1].json?["cookieConsents"] as? [String: Bool])?["analytics"], true)
        XCTAssertNil(storage.loadPendingDecision())
        XCTAssertEqual(second.consent["analytics"], true)
        XCTAssertEqual(storage.loadConsent()?["analytics"], true)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(captcha.tokenCount, 0)
    }

    func testTheRetryIsQuietOnAChallengeAndStopsAfterThreeLaunches() async {
        refuse(429)
        await launch().acceptAll()

        refuse(428, "captcha_required")
        for _ in 0..<3 {
            _ = await launch()
        }
        XCTAssertEqual(captcha.tokenCount, 0)
        XCTAssertEqual(posts.count, 4)
        XCTAssertEqual(storage.loadPendingDecision()?.attempts, 3)

        _ = await launch()
        XCTAssertEqual(posts.count, 4)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAPendingDecisionOlderThanSevenDaysIsDropped() async {
        let start = Date()
        refuse(429)
        await launch(at: start).acceptAll()

        accept()
        _ = await launch(at: start.addingTimeInterval(8 * 24 * 60 * 60))

        XCTAssertEqual(posts.count, 1)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testRefusalsThatResendingCannotChangeDropTheDecision() async {
        for status in [400, 404, 409, 422] {
            refuse(429)
            await launch().acceptAll()
            XCTAssertNotNil(storage.loadPendingDecision(), "\(status)")

            refuse(status)
            await launch().rejectAll()

            XCTAssertNil(storage.loadPendingDecision(), "\(status)")
        }
    }

    func testAForbiddenAnswerReachesTheAppAndIsNotRetried() async throws {
        refuse(403, "Identity token did not verify")
        let sdk = await launch()

        await sdk.acceptAll()
        _ = await launch()

        XCTAssertEqual(posts.count, 1)
        let error = try XCTUnwrap(errors.first as? ConsentIQAPIError)
        XCTAssertEqual(error, ConsentIQAPIError(statusCode: 403, message: "Identity token did not verify"))
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAForbiddenAnswerToTheRetryReachesTheAppToo() async {
        refuse(429)
        await launch().acceptAll()

        refuse(403, "Verified identity required")
        _ = await launch()

        XCTAssertEqual((errors.first as? ConsentIQAPIError)?.statusCode, 403)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAPropertyThatRequiresACaptchaKeepsNothingToRetry() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.captchaConfigJSON))
        refuse(429)
        await launch().acceptAll()

        XCTAssertNil(storage.loadPendingDecision())
    }

    func testClearAllForgetsAPendingDecision() async {
        refuse(429)
        await launch().acceptAll()

        storage.clearAll()

        XCTAssertNil(storage.loadPendingDecision())
    }
}
