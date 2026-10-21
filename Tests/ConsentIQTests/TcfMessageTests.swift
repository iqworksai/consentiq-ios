import XCTest
@testable import ConsentIQ

final class TcfMessageTests: XCTestCase {
    private func parse(_ json: String) -> TcfMessage? {
        TcfPageMessage(json: json)?.message
    }

    func testTokenIsReadOffEveryMessage() {
        XCTAssertEqual(TcfPageMessage(json: #"{"type":"show","token":"t-1"}"#)?.token, "t-1")
        XCTAssertNil(TcfPageMessage(json: #"{"type":"ready"}"#)?.token)
        XCTAssertNil(TcfPageMessage(json: #"{"type":"show","token":7}"#)?.token)
    }

    func testSimpleMessageTypes() {
        guard case .ready = parse(#"{"type":"ready"}"#) else { return XCTFail("ready") }
        guard case .current = parse(#"{"type":"current"}"#) else { return XCTFail("current") }
        guard case .show = parse(#"{"type":"show"}"#) else { return XCTFail("show") }
        guard case .notApplicable = parse(#"{"type":"not-applicable"}"#) else { return XCTFail("not-applicable") }
        guard case .closed = parse(#"{"type":"closed","extra":1}"#) else { return XCTFail("closed") }
    }

    func testErrorCarriesItsCode() {
        guard case .error(let code) = parse(#"{"type":"error","code":"no-cmp-id"}"#) else { return XCTFail("error") }
        XCTAssertEqual(code, "no-cmp-id")
        guard case .error(let missing) = parse(#"{"type":"error"}"#) else { return XCTFail("error without code") }
        XCTAssertNil(missing)
    }

    func testDecisionCarriesKeysStoredAndConsent() throws {
        guard case .decision(let decision) = parse(Fixtures.tcfDecisionJSON) else { return XCTFail("decision") }

        XCTAssertEqual(decision.keys["IABTCF_CmpSdkID"] as? Int, 300)
        XCTAssertEqual(decision.keys["IABTCF_PurposeConsents"] as? String, "1101")
        XCTAssertEqual(decision.keys.count, 9)
        let stored = try XCTUnwrap(decision.stored)
        XCTAssertEqual(stored["tcString"] as? String, "CQ-test")
        XCTAssertEqual(stored["vendorIds"] as? [Int], [1, 755])
        XCTAssertEqual(decision.consent, ["necessary": true, "analytics": true, "marketing": false])
        XCTAssertNil(decision.scope)
    }

    func testDecisionScopeMapsToTheSheetOutcomes() {
        func scope(_ raw: String) -> TcfDecision.Scope? {
            guard case .decision(let decision) = parse(#"{"type":"decision","keys":{},"scope":"\#(raw)"}"#) else { return nil }
            return decision.scope
        }
        XCTAssertEqual(scope("all"), .acceptAll)
        XCTAssertEqual(scope("none"), .rejectAll)
        XCTAssertEqual(scope("custom"), .custom)
        XCTAssertNil(scope("everything"))
    }

    func testDecisionWithoutKeysIsAnError() {
        guard case .error(let code) = parse(#"{"type":"decision","tcString":"x"}"#) else { return XCTFail("invalid decision") }
        XCTAssertEqual(code, TcfError.invalidDecision)
    }

    func testDecisionToleratesMissingStoredAndConsent() {
        guard case .decision(let decision) = parse(#"{"type":"decision","keys":{},"consent":{"analytics":"yes"}}"#) else {
            return XCTFail("decision")
        }
        XCTAssertNil(decision.stored)
        XCTAssertEqual(decision.consent, [:])
    }

    func testUnknownOrMalformedMessagesAreIgnored() {
        XCTAssertNil(parse(#"{"type":"token","token":"x"}"#))
        guard case .error(let code) = parse(#"{"type":"error","code":"tcf-off"}"#) else { return XCTFail("tcf-off") }
        XCTAssertEqual(code, TcfError.tcfOff)
        XCTAssertNil(parse(#"{"kind":"ready"}"#))
        XCTAssertNil(parse(#"["ready"]"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(""))
    }

    func testStartOptionsSerializeForThePage() throws {
        let options = TcfStartOptions(subjectId: "s-1", stored: nil, consent: ["necessary": true], reopen: false, token: "t-1")
        let arguments = options.arguments

        XCTAssertEqual(arguments["subjectId"] as? String, "s-1")
        XCTAssertTrue(arguments["stored"] is NSNull)
        XCTAssertEqual(arguments["consent"] as? [String: Bool], ["necessary": true])
        XCTAssertEqual(arguments["reopen"] as? Bool, false)
        XCTAssertEqual(arguments["token"] as? String, "t-1")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(arguments))
    }

    func testPageURLCarriesThePropertyKey() throws {
        let url = TcfSession.pageURL(apiURL: Fixtures.apiURL, propertyKey: "abc-123")
        XCTAssertEqual(url.absoluteString, "https://consent.example.test/api/public/tcf/mobile?key=abc-123")
        let trailingSlash = try XCTUnwrap(URL(string: "https://consent.iqworks.ai/"))
        XCTAssertEqual(
            TcfSession.pageURL(apiURL: trailingSlash, propertyKey: "abc").absoluteString,
            "https://consent.iqworks.ai/api/public/tcf/mobile?key=abc"
        )
    }

    // MARK: Config gate

    func testTcfBlockIsOptional() throws {
        XCTAssertNil(try Fixtures.decodeConfig().tcf)
    }

    func testGateNeedsEnabledAndAnIssuedCmpId() throws {
        let issued = try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: Fixtures.tcfJSON(cmpId: 2))).tcf)
        XCTAssertTrue(issued.isInAppEnabled)
        XCTAssertEqual(issued.cmpId, 2)
        XCTAssertEqual(issued.cmpVersion, 1)
        XCTAssertEqual(issued.gdprApplies, true)

        XCTAssertFalse(try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: Fixtures.tcfJSON(cmpId: 1))).tcf).isInAppEnabled)
        XCTAssertFalse(try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: Fixtures.tcfJSON(cmpId: 0))).tcf).isInAppEnabled)
        XCTAssertFalse(try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: Fixtures.tcfJSON(enabled: false))).tcf).isInAppEnabled)
    }

    func testRelativeVendorListPathDoesNotMatter() throws {
        let relative = #"{"enabled":true,"cmpId":300,"vendorListUrl":"/api/public/tcf/k/vendor-list?v=abc"}"#
        let tcf = try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: relative)).tcf)
        XCTAssertTrue(tcf.isInAppEnabled)
    }

    func testMalformedTcfFieldsNeverFailTheConfig() throws {
        let odd = #"{"enabled":true,"cmpId":"300","cmpVersion":[1],"gdprApplies":"yes","vendorIds":"all"}"#
        let tcf = try XCTUnwrap(Fixtures.decodeConfig(Fixtures.configJSON(tcf: odd)).tcf)
        XCTAssertTrue(tcf.enabled)
        XCTAssertNil(tcf.cmpId)
        XCTAssertNil(tcf.cmpVersion)
        XCTAssertFalse(tcf.isInAppEnabled)
        XCTAssertNil(tcf.gdprApplies)

        let config = try Fixtures.decodeConfig(Fixtures.configJSON(tcf: #""on""#))
        XCTAssertNil(config.tcf)
        XCTAssertEqual(config.property.id, "prop-1")
    }
}
