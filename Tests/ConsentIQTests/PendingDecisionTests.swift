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

    private func launch(at date: Date = Date(), subjectId: String? = nil, apiURL: URL = Fixtures.apiURL) async -> ConsentIQ {
        let sdk = ConsentIQ(
            storage: storage,
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: captcha.factory(),
            appAttestorFactory: { _ in nil }
        )
        sdk.now = { date }
        await sdk.initialize(ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: apiURL,
            subjectId: subjectId,
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

    func testAPendingDecisionIsNeverSentForSomeoneElse() async {
        refuse(429)
        await launch(subjectId: "user-a").acceptAll()
        XCTAssertNotNil(storage.loadPendingDecision())

        accept()
        _ = await launch(subjectId: "user-b")

        XCTAssertEqual(posts.count, 1)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAPendingDecisionIsNeverSentToAnotherServer() async {
        refuse(429)
        await launch(subjectId: "user-a").acceptAll()

        accept()
        _ = await launch(subjectId: "user-a", apiURL: URL(string: "https://staging.example.test")!)

        XCTAssertEqual(posts.count, 1)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testANewDecisionReplacesOneStillWaiting() async {
        refuse(429)
        let sdk = await launch()
        await sdk.acceptAll()
        XCTAssertNotNil(storage.loadPendingDecision())

        refuse(500)
        await sdk.rejectAll()

        XCTAssertNil(storage.loadPendingDecision())
        accept()
        _ = await launch()
        XCTAssertEqual(posts.count, 2)
    }

    func testANewerRecordOnTheServerWinsOverTheWaitingDecision() async {
        let decidedAt = Date(timeIntervalSince1970: 1_700_000_000)
        refuse(429)
        await launch(at: decidedAt, subjectId: "user-a").acceptAll()

        accept()
        StubURLProtocol.stub("GET", Fixtures.consentLookupPath("user-a"), StubResponse(json: Fixtures.savedConsentJSON))
        _ = await launch(at: decidedAt.addingTimeInterval(60), subjectId: "user-a")

        XCTAssertEqual(posts.count, 1, "the record dated 2026-01-01 is newer than the decision")
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAnOlderRecordOnTheServerDoesNotStopTheResend() async {
        let decidedAt = Date(timeIntervalSince1970: 1_800_000_000)
        refuse(429)
        await launch(at: decidedAt, subjectId: "user-a").acceptAll()

        accept()
        StubURLProtocol.stub("GET", Fixtures.consentLookupPath("user-a"), StubResponse(json: Fixtures.savedConsentJSON))
        _ = await launch(at: decidedAt.addingTimeInterval(60), subjectId: "user-a")

        XCTAssertEqual(posts.count, 2)
        XCTAssertNil(storage.loadPendingDecision())
    }

    func testATooManyRequestsAnswerThatArrivesAfterAResetIsIgnored() async throws {
        let sdk = await launch()
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(status: 429, json: #"{"error":"Too many requests"}"#, delay: 0.3))
        let submit = Task { await sdk.acceptAll() }
        var spins = 0
        while posts.isEmpty, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(posts.count, 1, "the submit is in flight")
        sdk.resetConsent()
        await submit.value

        XCTAssertNil(storage.loadPendingDecision())
    }

    func testAStoredDecisionFromAnOlderVersionIsDiscarded() {
        let olderFormat = #"{"cookieConsents":{},"marketingConsents":{},"attempts":0,"createdAt":0}"#
        defaults.set(Data(olderFormat.utf8), forKey: ConsentStorage.pendingKey)
        XCTAssertNil(storage.loadPendingDecision())
        XCTAssertNil(defaults.data(forKey: ConsentStorage.pendingKey))
    }

    func testClearAllForgetsAPendingDecision() async {
        refuse(429)
        await launch().acceptAll()

        storage.clearAll()

        XCTAssertNil(storage.loadPendingDecision())
    }
}
