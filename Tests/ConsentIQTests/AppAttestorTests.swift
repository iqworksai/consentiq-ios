import XCTest
import CryptoKit
@testable import ConsentIQ

final class FakeAppAttestService: AppAttestService, @unchecked Sendable {
    var isSupported = true
    var keyId = "key-1"
    var attestError: Error?
    var assertionError: Error?
    private(set) var generatedKeys = 0
    private(set) var attestHashes: [Data] = []
    private(set) var assertionHashes: [Data] = []

    func generateKey() async throws -> String {
        generatedKeys += 1
        return keyId
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let attestError { throw attestError }
        attestHashes.append(clientDataHash)
        return Data("attestation".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let assertionError { throw assertionError }
        assertionHashes.append(clientDataHash)
        return Data("assertion".utf8)
    }
}

final class AppAttestorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let challengeBytes = Data([1, 2, 3, 250])

    override func setUp() {
        super.setUp()
        suiteName = "ai.iqworks.consentiq.attest.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct Registration {
        let keyId: String
        let attestation: Data
        let challenge: Data
    }

    private final class Calls: @unchecked Sendable {
        var challenges = 0
        var registrations: [Registration] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeAttestor(
        _ service: FakeAppAttestService,
        registers: Bool = true,
        status: Int? = nil,
        apiURL: String = Fixtures.apiURL.absoluteString,
        calls: Calls
    ) -> AppAttestor {
        let challenge = challengeBytes
        let answer = status ?? (registers ? 204 : 403)
        return AppAttestor(
            service: service,
            defaults: defaults,
            apiURL: apiURL,
            propertyKey: Fixtures.propertyKey,
            now: { calls.now },
            challenge: {
                calls.challenges += 1
                return challenge
            },
            register: { keyId, attestation, challenge in
                calls.registrations.append(Registration(keyId: keyId, attestation: attestation, challenge: challenge))
                return answer
            }
        )
    }

    func testUnsupportedDevicesSendNothing() async {
        let service = FakeAppAttestService()
        service.isSupported = false
        let calls = Calls()
        let headers = await makeAttestor(service, calls: calls).headers(for: Data("{}".utf8))

        XCTAssertEqual(headers, [:])
        XCTAssertEqual(service.generatedKeys, 0)
        XCTAssertEqual(calls.challenges, 0)
    }

    func testRegistersOnceThenSignsEachBodyItsOwnHash() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        let attestor = makeAttestor(service, calls: calls)
        let first = Data(#"{"a":1}"#.utf8)
        let second = Data(#"{"a":2}"#.utf8)

        let headers = await attestor.headers(for: first)
        _ = await attestor.headers(for: second)

        XCTAssertEqual(headers, [
            "X-ConsentIQ-Attest-Key": "key-1",
            "X-ConsentIQ-Assertion": Data("assertion".utf8).base64EncodedString(),
        ])
        XCTAssertEqual(service.generatedKeys, 1)
        XCTAssertEqual(calls.challenges, 1)
        XCTAssertEqual(service.attestHashes, [Data(SHA256.hash(data: challengeBytes))])
        XCTAssertEqual(calls.registrations.map(\.keyId), ["key-1"])
        XCTAssertEqual(calls.registrations.first?.challenge, challengeBytes)
        XCTAssertEqual(service.assertionHashes, [Data(SHA256.hash(data: first)), Data(SHA256.hash(data: second))])
    }

    func testARegisteredKeySurvivesARelaunch() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        _ = await makeAttestor(service, calls: calls).headers(for: Data())
        let relaunched = await makeAttestor(service, calls: calls).headers(for: Data())

        XCTAssertEqual(relaunched["X-ConsentIQ-Attest-Key"], "key-1")
        XCTAssertEqual(service.generatedKeys, 1)
        XCTAssertEqual(calls.registrations.count, 1)
    }

    func testARefusedRegistrationSendsNothingAndWaitsForTheNextLaunch() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        let attestor = makeAttestor(service, registers: false, calls: calls)

        let first = await attestor.headers(for: Data())
        let second = await attestor.headers(for: Data())
        let relaunched = await makeAttestor(service, calls: calls).headers(for: Data())

        XCTAssertEqual(first, [:])
        XCTAssertEqual(second, [:])
        XCTAssertEqual(calls.registrations.count, 2, "one attempt this launch, one on the next")
        XCTAssertEqual(relaunched["X-ConsentIQ-Attest-Key"], "key-1")
    }

    func testAFailedAttestationSendsNothing() async {
        let service = FakeAppAttestService()
        service.attestError = URLError(.notConnectedToInternet)
        let calls = Calls()

        let headers = await makeAttestor(service, calls: calls).headers(for: Data())

        XCTAssertEqual(headers, [:])
        XCTAssertTrue(calls.registrations.isEmpty)
    }

    func testAKeyTheSystemRejectsIsReplacedOnTheNextLaunch() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        _ = await makeAttestor(service, calls: calls).headers(for: Data())
        service.assertionError = URLError(.unknown)

        let rejected = await makeAttestor(service, calls: calls).headers(for: Data())
        service.assertionError = nil
        service.keyId = "key-2"
        let replaced = await makeAttestor(service, calls: calls).headers(for: Data())

        XCTAssertEqual(rejected, [:])
        XCTAssertEqual(replaced["X-ConsentIQ-Attest-Key"], "key-2")
    }

    func testAKeyBelongsToOneServer() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        _ = await makeAttestor(service, calls: calls).headers(for: Data())
        service.keyId = "key-2"

        let production = await makeAttestor(service, apiURL: "https://prod.example.test", calls: calls).headers(for: Data())

        XCTAssertEqual(production["X-ConsentIQ-Attest-Key"], "key-2")
        XCTAssertEqual(calls.registrations.count, 2)
    }

    func testAnUnconfiguredAppWaitsDaysBeforeTryingToRegisterAgain() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        _ = await makeAttestor(service, status: 409, calls: calls).headers(for: Data())

        calls.now = calls.now.addingTimeInterval(24 * 60 * 60)
        let nextDay = await makeAttestor(service, calls: calls).headers(for: Data())
        XCTAssertEqual(nextDay, [:])
        XCTAssertEqual(calls.registrations.count, 1)
        XCTAssertEqual(service.generatedKeys, 1)

        calls.now = calls.now.addingTimeInterval(3 * 24 * 60 * 60)
        let later = await makeAttestor(service, calls: calls).headers(for: Data())
        XCTAssertEqual(later["X-ConsentIQ-Attest-Key"], "key-1")
        XCTAssertEqual(calls.registrations.count, 2)
    }

    func testAKeyChallengedThreeTimesInARowIsRegisteredAgain() async {
        let service = FakeAppAttestService()
        let calls = Calls()
        let attestor = makeAttestor(service, calls: calls)
        _ = await attestor.headers(for: Data())

        await attestor.attestedRequestWasChallenged()
        await attestor.attestedRequestWasChallenged()
        await attestor.attestedRequestWasAccepted()
        await attestor.attestedRequestWasChallenged()
        await attestor.attestedRequestWasChallenged()
        _ = await makeAttestor(service, calls: calls).headers(for: Data())
        XCTAssertEqual(calls.registrations.count, 1, "an acceptance resets the count")

        await attestor.attestedRequestWasChallenged()
        service.keyId = "key-2"
        let replaced = await makeAttestor(service, calls: calls).headers(for: Data())
        XCTAssertEqual(replaced["X-ConsentIQ-Attest-Key"], "key-2")
        XCTAssertEqual(calls.registrations.count, 2)
    }

    func testDecodesTheServersBase64URLChallenge() {
        XCTAssertEqual(decodeBase64URL("AQID-g"), challengeBytes)
        XCTAssertEqual(challengeBytes.base64URLEncodedString(), "AQID-g")
        XCTAssertNil(decodeBase64URL("not base64!"))
    }
}

@MainActor
final class AppAttestationSubmitTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
        StubURLProtocol.stub("POST", "/api/public/app-attest/challenge", StubResponse(json: #"{"challenge":"AQID-g"}"#))
        StubURLProtocol.stub("POST", "/api/public/app-attest/register", StubResponse(status: 204, data: Data()))
        suiteName = "ai.iqworks.consentiq.attest.submit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSubmissionsCarryTheAssertionOverTheirExactBody() async throws {
        let service = FakeAppAttestService()
        let defaults = defaults!
        let sdk = ConsentIQ(
            storage: ConsentStorage(userDefaults: defaults),
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: FakeCaptchaProvider().factory(),
            appAttestorFactory: { client in
                AppAttestor(
                    service: service,
                    defaults: defaults,
                    apiURL: client.apiURL.absoluteString,
                    propertyKey: client.propertyKey,
                    challenge: { try await client.appAttestChallenge() },
                    register: { try await client.registerAppAttestKey(keyId: $0, attestation: $1, challenge: $2) }
                )
            }
        )
        await sdk.initialize(ConsentIQConfig(propertyKey: Fixtures.propertyKey, apiURL: Fixtures.apiURL))

        await sdk.acceptAll()

        let register = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", "/api/public/app-attest/register").first?.json)
        XCTAssertEqual(register["keyId"] as? String, "key-1")
        XCTAssertEqual(register["challenge"] as? String, "AQID-g")
        XCTAssertEqual(register["propertyKey"] as? String, Fixtures.propertyKey)
        // The contract's vector: clientDataHash is SHA-256 of the decoded challenge bytes (01 02 03 FA),
        // never of its base64url text, which is what the server hashes too.
        XCTAssertEqual(
            service.attestHashes.first.map { $0.map { String(format: "%02x", $0) }.joined() },
            "bacdef9c76b37eb70caaf81ea41ecddd56d625b72e453de5eabbd59745279847"
        )
        let post = try XCTUnwrap(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).first)
        XCTAssertEqual(post.headers["X-ConsentIQ-Attest-Key"], "key-1")
        XCTAssertNotNil(post.headers["X-ConsentIQ-Assertion"])
        XCTAssertEqual(service.assertionHashes, [Data(SHA256.hash(data: try XCTUnwrap(post.body)))])
    }
}
