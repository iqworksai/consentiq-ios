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
        let config: PropertyConfig = try await request(path: "/api/public/config/\(Self.segment(propertyKey))")
        logger.debug("Config loaded for property \(config.property.id)")
        return config
    }

    /// The stored consent for `subjectId`. An id the app chose is read with its `identityToken`, from
    /// the records ConsentIQ verified; an id this SDK generated is read without one.
    public func getConsent(subjectId: String, identityToken: String? = nil) async throws -> ConsentLookup {
        logger.debug("Fetching consent")
        let path = "/api/public/consent/\(Self.segment(propertyKey))/\(Self.segment(subjectId))"
        let lookup: ConsentLookup
        if let identityToken {
            let body = try JSONEncoder().encode(["identityToken": identityToken])
            lookup = try await request(path: path, method: "POST", body: body)
        } else {
            lookup = try await request(path: path)
        }
        logger.debug("Consent loaded: found=\(lookup.consent != nil) expired=\(lookup.expired)")
        return lookup
    }

    public func submitConsent(_ submission: ConsentSubmission) async throws -> ConsentSubmissionResult {
        var body = submission
        body.propertyKey = propertyKey
        logger.debug("Submitting consent via \(body.consentMethod.rawValue)")
        let payload = try JSONEncoder().encode(body)
        let headers = await attestor?.headers(for: payload) ?? [:]
        let result: ConsentSubmissionResult
        do {
            result = try await request(path: "/api/public/consent", method: "POST", body: payload, headers: headers)
        } catch let error as ConsentIQAPIError where error.statusCode == 428 && !headers.isEmpty {
            // Challenged although this request carried a proof: the server may no longer know the key.
            await attestor?.attestedRequestWasChallenged()
            throw error
        }
        if !headers.isEmpty {
            await attestor?.attestedRequestWasAccepted()
        }
        logger.debug("Consent submitted")
        return result
    }

    public func verifyConsent(consentId: String) async throws -> ConsentVerification {
        try await request(path: "/api/public/verify/\(Self.segment(consentId))")
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

    /// The HTTP status of the registration: 204 registered it; anything else leaves it unregistered.
    func registerAppAttestKey(keyId: String, attestation: Data, challenge: Data) async throws -> Int {
        let body = try JSONEncoder().encode([
            "propertyKey": propertyKey,
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64URLEncodedString(),
        ])
        let (_, http) = try await send(path: "/api/public/app-attest/register", method: "POST", body: body)
        return http.statusCode
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
        var request = URLRequest(url: try url(for: path))
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

    /// One path segment, percent-encoded. A `/` in an app-chosen subject id stays inside its segment.
    static func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // The path arrives already encoded; appendingPathComponent would encode its `%` a second time.
    private func url(for encodedPath: String) throws -> URL {
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            throw ConsentIQAPIError(statusCode: 0, message: "Invalid API URL")
        }
        var base = components.percentEncodedPath
        if base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + encodedPath
        guard let url = components.url else {
            throw ConsentIQAPIError(statusCode: 0, message: "Invalid API URL")
        }
        return url
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
