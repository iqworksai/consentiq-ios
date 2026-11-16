import Foundation
import CryptoKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The App Attest calls the SDK makes; `DCAppAttestService` in an app, a fake in tests.
protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

#if canImport(DeviceCheck) && os(iOS)
struct DeviceCheckAppAttestService: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}
#endif

typealias AppAttestorFactory = @Sendable (ConsentIQAPIClient) -> AppAttestor?

let defaultAppAttestorFactory: AppAttestorFactory = { AppAttestor.shared(for: $0, service: makeDefaultAppAttestService()) }

func makeDefaultAppAttestService() -> (any AppAttestService)? {
    #if canImport(DeviceCheck) && os(iOS)
    return DeviceCheckAppAttestService()
    #else
    return nil
    #endif
}

/// Proves a submission comes from this app. The key is generated and registered with ConsentIQ once
/// per install and property; each submission then carries an assertion over its exact body. Where
/// App Attest is unsupported (simulators, older devices) or registration fails, nothing is sent and
/// the server answers with the captcha challenge instead.
actor AppAttestor {
    static let keyHeader = "X-ConsentIQ-Attest-Key"
    static let assertionHeader = "X-ConsentIQ-Assertion"

    private let service: any AppAttestService
    private let defaults: UserDefaults
    private let storageKey: String
    private let challenge: @Sendable () async throws -> Data
    private let register: @Sendable (_ keyId: String, _ attestation: Data, _ challenge: Data) async throws -> Bool
    private var registering: Task<String?, Never>?
    private var gaveUpThisLaunch = false

    init(
        service: any AppAttestService,
        defaults: UserDefaults,
        propertyKey: String,
        challenge: @escaping @Sendable () async throws -> Data,
        register: @escaping @Sendable (_ keyId: String, _ attestation: Data, _ challenge: Data) async throws -> Bool
    ) {
        self.service = service
        self.defaults = defaults
        self.storageKey = "consentiq_app_attest_key_\(propertyKey)"
        self.challenge = challenge
        self.register = register
    }

    func headers(for body: Data) async -> [String: String] {
        guard service.isSupported, let keyId = await registeredKey() else { return [:] }
        do {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: Data(SHA256.hash(data: body)))
            return [Self.keyHeader: keyId, Self.assertionHeader: assertion.base64EncodedString()]
        } catch {
            // A key the system no longer recognizes is replaced on the next launch.
            defaults.removeObject(forKey: storageKey)
            gaveUpThisLaunch = true
            return [:]
        }
    }

    private func registeredKey() async -> String? {
        if let stored = defaults.string(forKey: storageKey) { return stored }
        if gaveUpThisLaunch { return nil }
        if let registering { return await registering.value }
        let task = Task { await registerNewKey() }
        registering = task
        let keyId = await task.value
        registering = nil
        if let keyId {
            defaults.set(keyId, forKey: storageKey)
        } else {
            gaveUpThisLaunch = true
        }
        return keyId
    }

    private func registerNewKey() async -> String? {
        do {
            let keyId = try await service.generateKey()
            let challengeBytes = try await challenge()
            let attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: challengeBytes)))
            return try await register(keyId, attestation, challengeBytes) ? keyId : nil
        } catch {
            return nil
        }
    }

    private static let registry = AttestorRegistry()

    /// One attestor per API URL and property, so the SDK and its forms share one registration.
    static func shared(
        for client: ConsentIQAPIClient,
        service: (any AppAttestService)?,
        defaults: UserDefaults = .standard
    ) -> AppAttestor? {
        guard let service else { return nil }
        return registry.attestor(for: "\(client.apiURL.absoluteString)|\(client.propertyKey)") {
            AppAttestor(
                service: service,
                defaults: defaults,
                propertyKey: client.propertyKey,
                challenge: { try await client.appAttestChallenge() },
                register: { try await client.registerAppAttestKey(keyId: $0, attestation: $1, challenge: $2) }
            )
        }
    }
}

private final class AttestorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var attestors: [String: AppAttestor] = [:]

    func attestor(for key: String, make: () -> AppAttestor) -> AppAttestor {
        lock.lock(); defer { lock.unlock() }
        if let existing = attestors[key] { return existing }
        let created = make()
        attestors[key] = created
        return created
    }
}

/// base64url as the server sends its challenge, decoded to the raw bytes App Attest hashes.
func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
}
