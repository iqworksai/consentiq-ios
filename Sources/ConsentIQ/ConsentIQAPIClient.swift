import Foundation

public struct ConsentIQAPIError: Error, LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let message: String

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ConsentIQAPIClient: Sendable {
    public static let defaultAPIURL = URL(string: "https://consent.iqworks.ai")!

    public let propertyKey: String
    public let apiURL: URL
    private let session: URLSession
    private let logger: ConsentIQLogger
    /// Signs each submission so ConsentIQ knows it came from this app; nil sends none.
    var attestor: AppAttestor?

    public init(propertyKey: String, apiURL: URL = ConsentIQAPIClient.defaultAPIURL, session: URLSession = .shared, debug: Bool = false) {
        self.init(propertyKey: propertyKey, apiURL: apiURL, session: session, logger: ConsentIQLogger(debugEnabled: debug))
    }

    init(propertyKey: String, apiURL: URL, session: URLSession, logger: ConsentIQLogger) {
        self.propertyKey = propertyKey
        self.apiURL = apiURL
        self.session = session
        self.logger = logger
    }

    public func getConfig() async throws -> PropertyConfig {
        logger.debug("Fetching config for property \(propertyKey)")
        let config: PropertyConfig = try await request(path: "/api/public/config/\(propertyKey)")
        logger.debug("Config loaded for property \(config.property.id)")
        return config
    }

    public func getConsent(subjectId: String) async throws -> ConsentLookup {
        logger.debug("Fetching consent")
        let lookup: ConsentLookup = try await request(path: "/api/public/consent/\(propertyKey)/\(subjectId)")
        logger.debug("Consent loaded: found=\(lookup.consent != nil) expired=\(lookup.expired)")
        return lookup
    }

    public func submitConsent(_ submission: ConsentSubmission) async throws -> ConsentSubmissionResult {
        var body = submission
        body.propertyKey = propertyKey
        logger.debug("Submitting consent via \(body.consentMethod.rawValue)")
        let payload = try JSONEncoder().encode(body)
        let headers = await attestor?.headers(for: payload) ?? [:]
        let result: ConsentSubmissionResult = try await request(
            path: "/api/public/consent",
            method: "POST",
            body: payload,
            headers: headers
        )
        logger.debug("Consent submitted")
        return result
    }

    public func verifyConsent(consentId: String) async throws -> ConsentVerification {
        try await request(path: "/api/public/verify/\(consentId)")
    }

    func appAttestChallenge() async throws -> Data {
        struct Challenge: Decodable { let challenge: String }
        let body = try JSONEncoder().encode(["propertyKey": propertyKey])
        let response: Challenge = try await request(path: "/api/public/app-attest/challenge", method: "POST", body: body)
        guard let bytes = decodeBase64URL(response.challenge) else {
            throw ConsentIQAPIError(statusCode: 0, message: "Invalid challenge")
        }
        return bytes
    }

    /// True once ConsentIQ has registered the key (204); any other answer leaves it unregistered.
    func registerAppAttestKey(keyId: String, attestation: Data, challenge: Data) async throws -> Bool {
        let body = try JSONEncoder().encode([
            "propertyKey": propertyKey,
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64URLEncodedString(),
        ])
        let (_, http) = try await send(path: "/api/public/app-attest/register", method: "POST", body: body)
        return http.statusCode == 204
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let (data, http) = try await send(path: path, method: method, body: body, headers: headers)
        guard (200..<300).contains(http.statusCode) else {
            throw ConsentIQAPIError(statusCode: http.statusCode, message: Self.errorMessage(from: data, status: http.statusCode))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func send(path: String, method: String, body: Data?, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConsentIQAPIError(statusCode: 0, message: "Invalid response")
        }
        return (data, http)
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            return message
        }
        return "HTTP \(status)"
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
