import XCTest
@testable import ConsentIQ

@MainActor
final class ConsentIQTcfRobustnessTests: TcfSDKTestCase {
    func testEveryRunGetsAFreshTokenAndForeignMessagesAreDropped() async throws {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [
            #"{"type":"decision","keys":{"IABTCF_TCString":"forged"},"token":"wrong"}"#,
            #"{"type":"current","token":null}"#,
            FakeTcfPage.current,
        ]
        let sdk = makeSDK()
        await initialize(sdk)
        page.onStart = [FakeTcfPage.current]
        sdk.showPrivacyChoices()
        await sdk.tcfTask?.value

        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertEqual(standard.integer(forKey: "IABTCF_gdprApplies"), 1)
        let tokens = page.startOptions.map(\.token)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNotEqual(tokens[0], tokens[1])
        XCTAssertFalse(tokens[0].isEmpty)
    }

    func testPageCmpKeysAreIgnored() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [#"{"type":"decision","keys":{"IABTCF_CmpSdkID":10,"IABTCF_CmpSdkVersion":9,"IABTCF_TCString":"CQ"}}"#]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 300)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkVersion"), 1)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ")
    }

    func testTcfOffFromThePageClearsOwnedKeysWithoutGdprAppliesZero() async {
        TcfKeyStore().claimCmp(id: 300, version: 1)
        TcfKeyStore().write(keys: ["IABTCF_TCString": "CQ-old", "IABTCF_gdprApplies": 1])
        storage.saveTcfStored(["tcString": "CQ-old"])
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [#"{"type":"error","code":"tcf-off"}"#]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(remainingTcfKeys, [])
        XCTAssertNil(storage.loadTcfStored())
        XCTAssertFalse(sdk.isTcfActive)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertTrue(errors.isEmpty)
    }

    func testFailedPresentationEndsTheSessionInsteadOfHanging() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.failOnPresent = TcfError.noPresenter
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(errorCodes, [TcfError.noPresenter])
        XCTAssertNil(sdk.tcfTask)
        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(events, ["open"], "only the native sheet opened")
    }

    func testNativeChoiceAfterAFailureClearsOurOldDecision() async {
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.savedConsentJSON))
        TcfKeyStore().claimCmp(id: 300, version: 1)
        TcfKeyStore().write(keys: ["IABTCF_TCString": "CQ-all", "IABTCF_PurposeConsents": "1111"])
        storage.saveTcfStored(["tcString": "CQ-all"])
        stubConfig(tcf: Fixtures.tcfJSON())
        page.failOnLoad = TcfError.pageLoadFailed
        let sdk = makeSDK()
        await initialize(sdk)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ-all", "a failure alone changes nothing")

        await sdk.rejectAll()

        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertNil(standard.object(forKey: "IABTCF_PurposeConsents"))
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 300)
        XCTAssertNil(storage.loadTcfStored())
    }

    func testNativeChoiceWithoutAFailureLeavesTcfKeys() async {
        stubConfig(tcf: Fixtures.tcfJSON(gdprApplies: false))
        TcfKeyStore().claimCmp(id: 300, version: 1)
        TcfKeyStore().write(keys: ["IABTCF_TCString": "CQ"])
        let sdk = makeSDK()
        await initialize(sdk)

        await sdk.acceptAll()

        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ")
    }

    func testAnotherCmpsIdIsNeverClaimed() async {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        standard.set("other", forKey: "IABTCF_TCString")
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()

        await initialize(sdk)
        sdk.resetConsent()

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 10)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "other")
        XCTAssertNil(standard.object(forKey: "IABTCF_gdprApplies"))
        XCTAssertNil(standard.object(forKey: TcfKeyStore.writtenCmpIdKey))
    }

    func testDecisionInOurScreensTakesOverFromAnotherCmp() async {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 300)
        XCTAssertEqual(standard.object(forKey: TcfKeyStore.writtenCmpIdKey) as? Int, 300)
    }

    func testStaleOutcomeIsNotAppliedAfterReconfigure() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON]
        let sdk = makeSDK()
        page.afterPresent = { [weak sdk] in sdk?.endTcfSession() }

        await sdk.initialize(config())
        await waitUntil { [self] in page.closeCount == 1 }

        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertNil(storage.loadTcfStored())
        XCTAssertEqual(sdk.consent, ConsentIQ.defaultConsent)
        XCTAssertFalse(events.contains("save"))
    }

    func testOpenDuringPrewarmRunsAsAReopenWhenThePromptIsNotNeeded() async throws {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onLoad = []
        let sdk = makeSDK()
        await sdk.initialize(config())
        await waitUntil { [self] in page.loadCount == 1 }

        sdk.showPrivacyChoices()
        page.onLoad = [FakeTcfPage.ready]
        page.onStart = [FakeTcfPage.current]
        page.send(FakeTcfPage.ready)
        page.onStart = [FakeTcfPage.show]
        await waitUntil { [self] in page.startOptions.count == 2 }

        XCTAssertEqual(page.startOptions.map(\.reopen), [false, true])
        XCTAssertEqual(page.presented, [true])
        sdk.endTcfSession()
    }

    func testOpenDuringPrewarmIsAnsweredByThePromptItself() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onLoad = []
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON]
        let sdk = makeSDK()
        await sdk.initialize(config())
        await waitUntil { [self] in page.loadCount == 1 }

        sdk.showPrivacyChoices()
        page.send(FakeTcfPage.ready)
        await sdk.tcfTask?.value
        await waitUntil { sdk.tcfTask == nil }

        XCTAssertEqual(page.startOptions.count, 1)
        XCTAssertEqual(page.presented, [false])
    }

    func testExternalDismissalEndsTheSession() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        let sdk = makeSDK()
        await sdk.initialize(config())
        await waitUntil { [self] in !page.presented.isEmpty }

        page.dismissExternally()
        await waitUntil { sdk.tcfTask == nil }

        XCTAssertNil(sdk.tcfTask)
        XCTAssertEqual(events, ["open", "close"])
        XCTAssertEqual(page.closeCount, 1)
    }

    func testAnswerTimeoutAfterStartIsLongerThanReady() {
        XCTAssertEqual(TcfSession.defaultReadyTimeoutNanoseconds, 15_000_000_000)
        XCTAssertEqual(TcfSession.defaultAnswerTimeoutNanoseconds, 45_000_000_000)
    }

    func testNoAnswerAfterStartTimesOut() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        let sdk = makeSDK()
        sdk.tcfAnswerTimeoutNanoseconds = 50_000_000

        await initialize(sdk)

        XCTAssertEqual(page.startOptions.count, 1)
        XCTAssertEqual(errorCodes, [TcfError.timedOut])
    }

    func testResetClearsStoredTcfState() {
        storage.saveTcfStored(["tcString": "CQ-old"])
        let sdk = makeSDK()

        sdk.resetConsent()

        XCTAssertNil(storage.loadTcfStored())
        XCTAssertNil(defaults.object(forKey: ConsentStorage.tcfKey))
    }

    func testResetRemovesOurDecisionKeysAndKeepsCmpAndGdprApplies() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        page.onPresent = [Fixtures.tcfDecisionJSON]
        let sdk = makeSDK()
        await initialize(sdk)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ-test")

        sdk.resetConsent()

        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertNil(standard.object(forKey: "IABTCF_PurposeConsents"))
        XCTAssertNil(standard.object(forKey: "IABTCF_PublisherRestrictions2"))
        XCTAssertNil(standard.object(forKey: "IABTCF_PublisherCC"))
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkVersion") as? Int, 1)
        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 1)
    }

    func seedOurEarlierDecision() {
        TcfKeyStore().claimCmp(id: 300, version: 1)
        TcfKeyStore().writeGdprApplies(1)
        TcfKeyStore().write(keys: ["IABTCF_TCString": "CQ-old", "IABTCF_PurposeConsents": "11", "IABTCF_PublisherRestrictions2": "_1"])
    }

    var remainingTcfKeys: [String] {
        standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("IABTCF_") }.sorted()
    }

    func testTurningTcfOffRemovesEveryKeyWeWrote() async {
        for tcf in [nil, Fixtures.tcfJSON(enabled: false), Fixtures.tcfJSON(cmpId: 1)] {
            seedOurEarlierDecision()
            stubConfig(tcf: tcf)
            let sdk = makeSDK()

            await initialize(sdk)

            XCTAssertEqual(remainingTcfKeys, [], tcf ?? "absent")
            XCTAssertNil(standard.object(forKey: TcfKeyStore.writtenCmpIdKey))
            XCTAssertTrue(sdk.isSheetVisible)
        }
    }

    func testTurningTcfOffLeavesAnotherCmpsKeys() async {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        standard.set("other", forKey: "IABTCF_TCString")
        stubConfig(tcf: nil)
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 10)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "other")
    }

    func testConfigFailureLeavesOurKeys() async {
        seedOurEarlierDecision()
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(status: 500, json: "{}"))
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ-old")
    }

    func testResetClearsOurDecisionEvenWhenTcfIsOffThisSession() {
        seedOurEarlierDecision()
        let sdk = makeSDK()
        XCTAssertFalse(sdk.isTcfActive)

        sdk.resetConsent()

        XCTAssertEqual(remainingTcfKeys, ["IABTCF_CmpSdkID", "IABTCF_CmpSdkVersion", "IABTCF_gdprApplies"])
    }

    func testResetWithoutTcfLeavesAnotherCmpsKeys() {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        standard.set("other", forKey: "IABTCF_TCString")
        let sdk = makeSDK()

        sdk.resetConsent()

        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "other")
    }

    func testExpiredServerConsentClearsOurDecision() async {
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.expiredConsentJSON))
        stubConfig(tcf: Fixtures.tcfJSON())
        storage.saveTcfStored(["tcString": "CQ-old"])
        standard.set("CQ-old", forKey: "IABTCF_TCString")
        page.onStart = [FakeTcfPage.current]
        let sdk = makeSDK()

        await initialize(sdk)

        XCTAssertNil(standard.object(forKey: "IABTCF_TCString"))
        XCTAssertNil(page.startOptions.first?.stored)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
    }

    func testReinitializingCancelsARunningSession() async {
        stubConfig(tcf: Fixtures.tcfJSON())
        page.onStart = [FakeTcfPage.show]
        let sdk = makeSDK()
        await sdk.initialize(config())
        await waitUntil { [self] in !page.presented.isEmpty }
        XCTAssertEqual(page.presented, [false])

        page.onStart = [FakeTcfPage.current]
        await initialize(sdk)

        await waitUntil { [self] in page.closeCount == 2 }
        XCTAssertEqual(page.startOptions.count, 2)
        XCTAssertEqual(page.closeCount, 2)
        XCTAssertTrue(errors.isEmpty)
    }
}
