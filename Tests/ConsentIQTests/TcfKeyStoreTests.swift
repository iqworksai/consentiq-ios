import XCTest
@testable import ConsentIQ

func clearStandardTcfKeys() {
    let standard = UserDefaults.standard
    standard.removeObject(forKey: TcfKeyStore.writtenCmpIdKey)
    for key in standard.dictionaryRepresentation().keys where key.hasPrefix("IABTCF_") {
        standard.removeObject(forKey: key)
    }
}

final class TcfKeyStoreTests: XCTestCase {
    private let standard = UserDefaults.standard

    override func setUp() {
        super.setUp()
        clearStandardTcfKeys()
    }

    override func tearDown() {
        clearStandardTcfKeys()
        super.tearDown()
    }

    func testNumbersAreWrittenAsIntegersAndStringsAsStrings() throws {
        let keys = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"IABTCF_PolicyVersion":5,"IABTCF_gdprApplies":1,"IABTCF_TCString":"CQ-x"}"#.utf8))
                as? [String: Any]
        )

        TcfKeyStore().write(keys: keys)

        XCTAssertEqual(standard.object(forKey: "IABTCF_PolicyVersion") as? Int, 5)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_gdprApplies"), 1)
        XCTAssertFalse(standard.object(forKey: "IABTCF_gdprApplies") is String)
        XCTAssertEqual(standard.object(forKey: "IABTCF_TCString") as? String, "CQ-x")
    }

    func testBooleansBecomeIntegersAndOtherValuesAndKeysAreSkipped() {
        TcfKeyStore().write(keys: [
            "IABTCF_PurposeOneTreatment": true,
            "IABTCF_Nested": ["a": 1],
            "IABTCF_Null": NSNull(),
            "not_iab": "x",
        ])

        XCTAssertEqual(standard.object(forKey: "IABTCF_PurposeOneTreatment") as? Int, 1)
        XCTAssertNil(standard.object(forKey: "IABTCF_Nested"))
        XCTAssertNil(standard.object(forKey: "IABTCF_Null"))
        XCTAssertNil(standard.object(forKey: "not_iab"))
    }

    func testStalePublisherRestrictionsAreRemoved() {
        standard.set("01", forKey: "IABTCF_PublisherRestrictions1")
        standard.set("_2", forKey: "IABTCF_PublisherRestrictions3")
        standard.set("12", forKey: "IABTCF_PublisherRestrictions11")
        standard.set("keep", forKey: "IABTCF_TCString")

        TcfKeyStore().write(keys: ["IABTCF_PublisherRestrictions3": "1_"])

        XCTAssertNil(standard.object(forKey: "IABTCF_PublisherRestrictions1"))
        XCTAssertEqual(standard.string(forKey: "IABTCF_PublisherRestrictions3"), "1_")
        XCTAssertNil(standard.object(forKey: "IABTCF_PublisherRestrictions11"))
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "keep")
        XCTAssertEqual(TcfKeyStore.publisherRestrictionKeys.count, 11)
    }

    private func writeFullDecision() {
        var keys: [String: Any] = [:]
        for key in TcfKeyStore.decisionKeys {
            keys[key] = key.hasSuffix("Treatment") || key.hasSuffix("Texts") || key.hasSuffix("PolicyVersion") ? 1 : "x"
        }
        keys["IABTCF_gdprApplies"] = 1
        TcfKeyStore().write(keys: keys)
    }

    func testClearDecisionRemovesDecisionKeysButKeepsCmpAndGdprApplies() {
        let store = TcfKeyStore()
        store.claimCmp(id: 300, version: 1)
        writeFullDecision()

        store.clearDecision()

        for key in TcfKeyStore.decisionKeys {
            XCTAssertNil(standard.object(forKey: key), key)
        }
        XCTAssertEqual(TcfKeyStore.decisionKeys.count, 26)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkVersion") as? Int, 1)
        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 1)
    }

    func testClearDecisionNeverTouchesAnotherCmpsKeys() {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        writeFullDecision()
        TcfKeyStore().clearDecision()
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "x")

        TcfKeyStore().claimCmp(id: 300, version: 1)
        TcfKeyStore().clearDecision()
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "x", "a claim never succeeds over another CMP's ID")

        TcfKeyStore().takeOverCmp(id: 300, version: 1)
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        TcfKeyStore().clearDecision()
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "x", "another CMP has since taken over")
    }

    func testClaimOnlyWhenAbsentOrAlreadyOurs() {
        let store = TcfKeyStore()
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        standard.set(4, forKey: "IABTCF_CmpSdkVersion")

        XCTAssertFalse(store.claimCmp(id: 300, version: 1))
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 10)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkVersion"), 4)
        XCTAssertNil(standard.object(forKey: TcfKeyStore.writtenCmpIdKey))
        XCTAssertFalse(store.isOurs)
        store.writeGdprApplies(0)
        XCTAssertNil(standard.object(forKey: "IABTCF_gdprApplies"), "never written over another CMP")

        standard.removeObject(forKey: "IABTCF_CmpSdkID")
        XCTAssertTrue(store.claimCmp(id: 300, version: 1))
        XCTAssertTrue(store.isOurs)
        XCTAssertTrue(store.claimCmp(id: 300, version: 2))
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkVersion"), 2)

        standard.removeObject(forKey: TcfKeyStore.writtenCmpIdKey)
        XCTAssertTrue(store.claimCmp(id: 300, version: 2), "an ID equal to ours is ours: IAB issues each once")
    }

    func testPageCannotWriteTheCmpKeys() {
        TcfKeyStore().claimCmp(id: 300, version: 1)

        TcfKeyStore().write(keys: ["IABTCF_CmpSdkID": 10, "IABTCF_CmpSdkVersion": 9, "IABTCF_TCString": "CQ"])

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 300)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkVersion"), 1)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "CQ")
    }

    func testClearAllRemovesEveryKeyWeWroteAndTheMarker() {
        let store = TcfKeyStore()
        store.claimCmp(id: 300, version: 1)
        store.writeGdprApplies(1)
        writeFullDecision()

        store.clearAll()

        let left = standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("IABTCF_") }
        XCTAssertEqual(left, [])
        XCTAssertNil(standard.object(forKey: TcfKeyStore.writtenCmpIdKey))
    }

    func testClearAllNeverTouchesAnotherCmpsKeys() {
        standard.set(10, forKey: "IABTCF_CmpSdkID")
        standard.set(1, forKey: "IABTCF_gdprApplies")
        writeFullDecision()

        TcfKeyStore().clearAll()

        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkID"), 10)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_gdprApplies"), 1)
        XCTAssertEqual(standard.string(forKey: "IABTCF_TCString"), "x")
    }

    func testGdprAppliesAndCmpWrites() {
        let store = TcfKeyStore()

        store.claimCmp(id: 300, version: 2)
        store.writeGdprApplies(0)

        XCTAssertEqual(standard.object(forKey: "IABTCF_gdprApplies") as? Int, 0)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkID") as? Int, 300)
        XCTAssertEqual(standard.object(forKey: "IABTCF_CmpSdkVersion") as? Int, 2)
        XCTAssertEqual(standard.object(forKey: TcfKeyStore.writtenCmpIdKey) as? Int, 300)

        store.claimCmp(id: 300, version: nil)
        XCTAssertEqual(standard.integer(forKey: "IABTCF_CmpSdkVersion"), 2)
    }
}
