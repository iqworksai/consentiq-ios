import XCTest
@testable import ConsentIQ

final class APIClientTests: XCTestCase {
    private var client: ConsentIQAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = ConsentIQAPIClient(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            session: URLSession(configuration: StubURLProtocol.sessionConfiguration)
        )
    }

    func testGetConfigHitsPropertyURLAndDecodes() async throws {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))

        let config = try await client.getConfig()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://consent.example.test/api/public/config/pk_test_property")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(config.property.id, "prop-1")
        XCTAssertEqual(config.property.platform, "ios")
        XCTAssertEqual(config.resolvedRegulation, "DPDPA")
        XCTAssertEqual(config.categories.map(\.code), ["necessary", "analytics", "marketing", "functional"])
        XCTAssertEqual(config.banner?.primaryColor, "#112233")
        XCTAssertEqual(config.labels["ar"]?.acceptAll, "قبول الكل")
        XCTAssertEqual(config.rtl, ["ar", "ur", "ks", "sd"])
        XCTAssertFalse(config.requireCaptcha)
        XCTAssertEqual(config.privacyNotices.first?.version, 3)
    }

    func testConfigDecodingToleratesMissingAndUnknownKeys() throws {
        let minimal = #"{"property":{"id":"p"},"banner":{},"resolvedRegulation":null,"extra":[1,2,3]}"#
        let config = try Fixtures.decodeConfig(minimal)

        XCTAssertEqual(config.property.id, "p")
        XCTAssertNil(config.property.defaultLanguage)
        XCTAssertEqual(config.property.supportedLanguages, [])
        XCTAssertEqual(config.categories.count, 0)
        XCTAssertNil(config.resolvedRegulation)
        XCTAssertFalse(config.requireCaptcha)
        XCTAssertFalse(config.autoBlock)
        XCTAssertEqual(config.labels.count, 0)
        XCTAssertNotNil(config.banner)
        XCTAssertNil(config.banner?.noticeUrl)
        XCTAssertFalse(config.banner?.showLogo ?? true)
    }

    func testGetConsentHitsSubjectURL() async throws {
        StubURLProtocol.stub("GET", Fixtures.consentLookupPath("subj-1"), StubResponse(json: Fixtures.savedConsentJSON))

        let lookup = try await client.getConsent(subjectId: "subj-1")

        XCTAssertEqual(StubURLProtocol.requests.first?.url.absoluteString,
                       "https://consent.example.test/api/public/consent/pk_test_property/subj-1")
        XCTAssertFalse(lookup.expired)
        XCTAssertEqual(lookup.consent?.id, "c-1")
        XCTAssertEqual(lookup.consent?.cookieConsents["analytics"], true)
        XCTAssertEqual(lookup.consent?.marketingConsents?["email"], true)
        XCTAssertNil(lookup.consent?.expiresAt)
        XCTAssertNil(lookup.consent?.consentVersion)
        XCTAssertEqual(lookup.consent?.regulationApplied, "DPDPA")
    }

    func testGetConsentPassesExpiredThrough() async throws {
        StubURLProtocol.stub("GET", Fixtures.consentLookupPath("subj-1"), StubResponse(json: Fixtures.expiredConsentJSON))

        let lookup = try await client.getConsent(subjectId: "subj-1")

        XCTAssertNil(lookup.consent)
        XCTAssertTrue(lookup.expired)
    }

    func testGetConsentDefaultsExpiredToFalseWhenAbsent() async throws {
        StubURLProtocol.stub("GET", Fixtures.consentLookupPath("subj-1"), StubResponse(json: Fixtures.noConsentJSON))

        let lookup = try await client.getConsent(subjectId: "subj-1")

        XCTAssertNil(lookup.consent)
        XCTAssertFalse(lookup.expired)
    }

    func testSubmitConsentPostsJSONBody() async throws {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))

        let result = try await client.submitConsent(ConsentSubmission(
            propertyKey: "ignored-overridden-by-client",
            subjectId: "subj-1",
            subjectType: .user,
            cookieConsents: ["necessary": true, "analytics": true],
            marketingConsents: ["email": false],
            consentMethod: .form,
            consentVersion: "v2"
        ))

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://consent.example.test/api/public/consent")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(request.json)
        XCTAssertEqual(body["propertyKey"] as? String, Fixtures.propertyKey)
        XCTAssertEqual(body["subjectId"] as? String, "subj-1")
        XCTAssertEqual(body["subjectType"] as? String, "user")
        XCTAssertEqual(body["consentMethod"] as? String, "form")
        XCTAssertEqual(body["consentVersion"] as? String, "v2")
        XCTAssertEqual(body["cookieConsents"] as? [String: Bool], ["necessary": true, "analytics": true])
        XCTAssertEqual(body["marketingConsents"] as? [String: Bool], ["email": false])
        XCTAssertNil(body["geoCountry"])
        XCTAssertNil(body["geoSource"])

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.consentId, "c-2")
        XCTAssertEqual(result.proofHash, "abc123")
    }

    func testSubmitOmitsAbsentMaps() async throws {
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))

        _ = try await client.submitConsent(ConsentSubmission(
            propertyKey: Fixtures.propertyKey,
            subjectId: "subj-1",
            marketingConsents: ["email": true],
            consentMethod: .form
        ))

        let body = try XCTUnwrap(StubURLProtocol.requests.first?.json)
        XCTAssertNil(body["cookieConsents"])
        XCTAssertNil(body["subjectType"])
        XCTAssertNil(body["captchaToken"])
        XCTAssertEqual(body["consentMethod"] as? String, "form")
    }

    func testVerifyConsentHitsVerifyURL() async throws {
        let json = #"{"verified":true,"consent":{"id":"c-1","consentedAt":"2026-01-01T00:00:00Z","proofHash":"h"}}"#
        StubURLProtocol.stub("GET", "/api/public/verify/c-1", StubResponse(json: json))

        let verification = try await client.verifyConsent(consentId: "c-1")

        XCTAssertEqual(StubURLProtocol.requests.first?.url.absoluteString, "https://consent.example.test/api/public/verify/c-1")
        XCTAssertTrue(verification.verified)
        XCTAssertEqual(verification.consent?.proofHash, "h")
    }

    func testErrorBodyMessageIsSurfaced() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 404, json: #"{"error":"Property not found"}"#))

        do {
            _ = try await client.getConfig()
            XCTFail("Expected an error")
        } catch let error as ConsentIQAPIError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.message, "Property not found")
            XCTAssertEqual(error.localizedDescription, "Property not found")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNonJSONErrorFallsBackToHTTPStatus() async {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 503, json: "<html>upstream</html>"))

        do {
            _ = try await client.getConfig()
            XCTFail("Expected an error")
        } catch let error as ConsentIQAPIError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.message, "HTTP 503")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testCaptchaTokenIsSentAndRefusalSurfacesServerMessage() async throws {
        StubURLProtocol.stub("POST", Fixtures.consentPath,
                             StubResponse(status: 400, json: #"{"error":"Captcha verification failed. Please try again."}"#))

        do {
            _ = try await client.submitConsent(ConsentSubmission(
                propertyKey: Fixtures.propertyKey,
                subjectId: "s",
                cookieConsents: ["necessary": true],
                captchaToken: "expired-token"
            ))
            XCTFail("Expected an error")
        } catch let error as ConsentIQAPIError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.message, "Captcha verification failed. Please try again.")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.json)
        XCTAssertEqual(body["captchaToken"] as? String, "expired-token")
    }

    func testTransportFailurePropagates() async {
        do {
            _ = try await client.getConfig()
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse(error is ConsentIQAPIError)
        }
    }
}
