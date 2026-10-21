import XCTest
@testable import ConsentIQ

@MainActor
final class ConsentIQTcfTests: TcfSDKTestCase {
    // MARK: Gate

    func testNoTcfBlockKeepsTheNativeSheetAndWritesNoKeys() async {
        stubConfig(tcf: nil)
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertFalse(sdk.isTcfActive)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(page.requestedURLs, [])
        XCTAssertNil(standard.object(forKey: "IABTCF_CmpSdkID"))
        XCTAssertNil(standard.object(forKey: "IABTCF_gdprApplies"))
    }

    func testUnissuedCmpIdKeepsTheNativeSheetAndWritesNoKeys() async {
        stubConfig(tcf: Fixtures.tcfJSON(cmpId: 1))
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertFalse(sdk.isTcfActive)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(page.requestedURLs, [])
        XCTAssertNil(standard.object(forKey: "IABTCF_CmpSdkID"))
    }

    func testGdprNotApplyingWritesZeroAndKeepsTheNativeSheet() async {
        stubConfig(tcf: Fixtures.tcfJSON(gdprApplies: false))
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertFalse(sdk.isTcfActive)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(page.requestedURLs, [])
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkVersion") as? Int, 1)
        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 0)
        XCTAssertNil(defaults.object(forKey: "IABTCF_gdprApplies"))
    }

    // MARK: First prompt

    func testFirstPromptStartsThePageWithStoredStateAndNoNativeSheet() async throws {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        let sdk = makeSDK()

        await sdk.initialize(config())
        await waitUntil { [self] in !page.presented.isEmpty }

        XCTAssertTrue(sdk.isTcfActive)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(page.requestedURLs.map(\.absoluteString), ["https://consent.example.test/api/public/tcf/mobile?key=\(Fixtures.propertyKey)"])
        let options = try XCTUnwrap(page.startOptions.first)
        XCTAssertEqual(options.subjectId, sdk.subjectId)
        XCTAssertNil(options.stored)
        XCTAssertEqual(options.consent, ConsentIQ.defaultConsent)
        XCTAssertFalse(options.reopen)
        XCTAssertEqual(page.presented, [false])
        XCTAssertEqual(events, ["open"])

        sdk.showSheet()
        XCTAssertEqual(page.requestedURLs.count, 1, "a second open while the page is up is ignored")
        sdk.endTcfSession()
    }

    func testCurrentDecisionWritesGdprAppliesAndShowsNothing() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 1)
        XCTAssertEqual(page.presented, [])
        XCTAssertEqual(page.closeCount, 1)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertTrue(sdk.isTcfActive)
        XCTAssertEqual(events, [])
        XCTAssertNil(sdk.tcfTask)
    }

    func testDecisionWritesKeysStoresStateAndUpdatesConsentWithoutSubmitting() async throws {
        stubConfig(tcf: Fixtures.tcfJSON())
        standard.set("stale", forKey: "IABTCF_PublisherRestrictions7")
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 1)
        XCTAssertEqual(standard.object(forKey: "IABTCF_TCString") as? String, "CQ-test")
        XCTAssertEqual(standard.object(forKey: "IABTCF_PublisherRestrictions2") as? String, "_1")
        XCTAssertNil(standard.object(forKey: "IABTCF_PublisherRestrictions7"))
        XCTAssertNil(defaults.object(forKey: "IABTCF_TCString"))
        XCTAssertNil(standard.object(forKey: ConsentStorage.tcfKey))

        let stored = try XCTUnwrap(storage.loadTcfStored())
        XCTAssertEqual(stored["tcString"] as? String, "CQ-test")
        XCTAssertEqual(stored["restrictionsKey"] as? String, "2:1:755")

        let expected: ConsentState = ["necessary": true, "analytics": true, "marketing": false]
        XCTAssertEqual(sdk.consent, expected)
        XCTAssertEqual(storage.loadConsent(), expected)
        XCTAssertTrue(sdk.hasConsent("analytics"))
        XCTAssertEqual(events, ["open", "save", "change:true"])
        XCTAssertEqual(page.closeCount, 1)
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(StubURLProtocol.requests(matching: "POST", Fixtures.consentPath).count, 0)
    }

    private func decide(scope: String?, consent: String) async -> [String] {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON(scope: scope, consent: consent)]
        events = []
        let sdk = makeSDK()
        await initialize(sdk)
        return events
    }

    func testDecisionScopePicksTheAcceptRejectOrSaveCallback() async {
        let all = #"{"necessary":true,"analytics":true,"marketing":true,"functional":true}"#
        let none = #"{"necessary":true,"analytics":false,"marketing":false,"functional":false}"#
        let some = #"{"necessary":true,"analytics":true,"marketing":false,"functional":false}"#

        let accepted = await decide(scope: "all", consent: some)
        XCTAssertEqual(accepted, ["open", "accept", "change:true"])
        let rejected = await decide(scope: "none", consent: all)
        XCTAssertEqual(rejected, ["open", "reject", "change:true"])
        let saved = await decide(scope: "custom", consent: all)
        XCTAssertEqual(saved, ["open", "save", "change:true"])

        let inferredAll = await decide(scope: nil, consent: all)
        XCTAssertEqual(inferredAll, ["open", "accept", "change:true"])
        let inferredNone = await decide(scope: nil, consent: none)
        XCTAssertEqual(inferredNone, ["open", "reject", "change:false"])
        let inferredSome = await decide(scope: "unknown", consent: some)
        XCTAssertEqual(inferredSome, ["open", "save", "change:true"])
    }

    // MARK: Fallbacks

    func testNotApplicableWritesZeroAndFallsBackToTheNativeSheet() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.notApplicable]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 0)
        XCTAssertFalse(sdk.isTcfActive)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(page.closeCount, 1)
        XCTAssertEqual(events, ["open"])
        XCTAssertTrue(errors.isEmpty)
    }

    func testPageErrorReportsAndFallsBackToTheNativeSheet() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [#"{"type":"error","code":"no-cmp-id"}"#]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(errorCodes, ["no-cmp-id"])
        XCTAssertTrue(sdk.isTcfActive, "a failure is retried on the next open")
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(page.closeCount, 1)
        XCTAssertNil(standard.object(forKey: "IABTCF_gdprApplies"))
        XCTAssertTrue(logLines.contains("[ConsentIQ] TCF screen unavailable, using the consent sheet: no-cmp-id"), "\(logLines)")
    }

    func testFallbackKeepsTheSheetClosedWhenConsentAlreadyExists() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.savedConsentJSON))
        page.failOnLoad = TcfError.pageLoadFailed
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(errorCodes, [TcfError.pageLoadFailed])
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(sdk.consent["analytics"], true)
    }

    func testNoReadyTimesOutAndFallsBack() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onLoad = []
        let sdk = makeSDK()
        sdk.tcfReadyTimeoutNanoseconds = 50_000_000

        await initialize(sdk)

        XCTAssertEqual(errorCodes, [TcfError.timedOut])
        XCTAssertEqual(page.startOptions.count, 0)
        XCTAssertTrue(sdk.isSheetVisible)
    }

    func testUnavailablePageFallsBack() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        let sdk = makeSDK(pageAvailable: false)

        await initialize(sdk)

        XCTAssertEqual(errorCodes, [TcfError.unavailable])
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertTrue(sdk.isTcfActive, "a failure is retried on the next open")
    }

    func testMessagesBeforeStartAreIgnored() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onLoad = [FakeTcfPage.show, FakeTcfPage.current, Fixtures.tcfDecisionJSON, FakeTcfPage.ready]
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(page.presented, [])
        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 1)
    }

    // MARK: Re-open

    func testReopenStartsWithStoredStateAndCloseKeepsKeys() async throws {
        stubConfig(tcf: Fixtures.tcfJSON())
        storage.saveTcfStored(["tcString": "CQ-old", "vendorIds": [1], "restrictionsKey": ""])
        storage.saveConsent(["necessary": true, "analytics": true])
        standard.set("CQ-old", forKey: "IABTCF_TCString")
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()
        await initialize(sdk)

        page.onStart = [FakeTcfPage.show]
        page.onPresent = [FakeTcfPage.closed]
        sdk.showPrivacyChoices()
        await sdk.tcfTask?.value

        let options = try XCTUnwrap(page.startOptions.last)
        XCTAssertTrue(options.reopen)
        XCTAssertEqual(options.stored?["tcString"] as? String, "CQ-old")
        XCTAssertEqual(options.consent["analytics"], true)
        XCTAssertEqual(page.presented, [true])
        XCTAssertEqual(page.closeCount, 2)
        XCTAssertEqual(events, ["open", "close"])
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ-old")
        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertTrue(sdk.isTcfActive)
    }

    func testReopenErrorOpensTheNativeSheet() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()
        await initialize(sdk, autoShow: false)
        XCTAssertEqual(page.startOptions.count, 0, "autoShow off never starts the page by itself")

        page.onStart = [#"{"type":"error","code":"500"}"#]
        sdk.showSheet()
        await sdk.tcfTask?.value

        XCTAssertEqual(errorCodes, ["500"])
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(events, ["open"])

        sdk.hideSheet()
        page.onStart = [FakeTcfPage.current]
        sdk.showSheet()
        await sdk.tcfTask?.value
        XCTAssertEqual(page.startOptions.count, 2, "the next explicit open retries the TCF screens")
        XCTAssertFalse(sdk.isSheetVisible)
    }
}
