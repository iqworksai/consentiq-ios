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
        logger.debug("Fetching consent for subject \(subjectId)")
        let lookup: ConsentLookup = try await request(path: "/api/public/consent/\(propertyKey)/\(subjectId)")
        logger.debug("Consent loaded: found=\(lookup.consent != nil) expired=\(lookup.expired)")
        return lookup
    }

    public func submitConsent(_ submission: ConsentSubmission) async throws -> ConsentSubmissionResult {
        var body = submission
        body.propertyKey = propertyKey
        logger.debug("Submitting consent for subject \(body.subjectId) via \(body.consentMethod.rawValue)")
        let payload = try JSONEncoder().encode(body)
        let result: ConsentSubmissionResult = try await request(path: "/api/public/consent", method: "POST", body: payload)
        logger.debug("Consent submitted: \(result.consentId)")
        return result
    }

    public func verifyConsent(consentId: String) async throws -> ConsentVerification {
        try await request(path: "/api/public/verify/\(consentId)")
    }

    private func request<Response: Decodable>(path: String, method: String = "GET", body: Data? = nil) async throws -> Response {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConsentIQAPIError(statusCode: 0, message: "Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ConsentIQAPIError(statusCode: http.statusCode, message: Self.errorMessage(from: data, status: http.statusCode))
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            return message
        }
        return "HTTP \(status)"
    }
}
