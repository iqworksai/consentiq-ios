import Foundation
@testable import ConsentIQ

@MainActor
final class FakeCaptchaProvider: CaptchaTokenProviding {
    var result: Result<String, Error> = .success("tok")
    private(set) var tokenCount = 0
    private(set) var requestedAPIURLs: [URL] = []

    func factory(available: Bool = true) -> CaptchaProviderFactory {
        { [self] apiURL in
            requestedAPIURLs.append(apiURL)
            guard available else { return nil }
            return self
        }
    }

    func token() async throws -> String {
        tokenCount += 1
        return try result.get()
    }
}
