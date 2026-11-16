import Foundation
@testable import ConsentIQ

@MainActor
final class FakeCaptchaProvider: CaptchaTokenProviding {
    var result: Result<String, Error> = .success("tok")
    private(set) var tokenCount = 0
    private(set) var requestedAPIURLs: [URL] = []
    private(set) var requestedPropertyKeys: [String] = []

    func factory(available: Bool = true) -> CaptchaProviderFactory {
        { [self] apiURL, propertyKey in
            requestedAPIURLs.append(apiURL)
            requestedPropertyKeys.append(propertyKey)
            guard available else { return nil }
            return self
        }
    }

    func token() async throws -> String {
        tokenCount += 1
        return try result.get()
    }
}
