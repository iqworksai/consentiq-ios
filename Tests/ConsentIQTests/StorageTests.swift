import XCTest
@testable import ConsentIQ

final class StorageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: ConsentStorage!

    override func setUp() {
        super.setUp()
        suiteName = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ConsentStorage(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testConsentRoundTripsAsJSONUnderContractKey() throws {
        XCTAssertNil(storage.loadConsent())

        storage.saveConsent(["necessary": true, "analytics": true, "marketing": false])

        let raw = try XCTUnwrap(defaults.data(forKey: "consentiq_consent"))
        let decoded = try JSONSerialization.jsonObject(with: raw) as? [String: Bool]
        XCTAssertEqual(decoded, ["necessary": true, "analytics": true, "marketing": false])
        XCTAssertEqual(storage.loadConsent(), ["necessary": true, "analytics": true, "marketing": false])
    }

    func testCorruptConsentReadsAsNil() {
        defaults.set(Data("not json".utf8), forKey: "consentiq_consent")
        XCTAssertNil(storage.loadConsent())
    }

    func testSubjectIdIsGeneratedOnceAndPersisted() throws {
        XCTAssertNil(storage.loadSubjectId())

        let first = storage.getOrCreateSubjectId()
        let second = storage.getOrCreateSubjectId()

        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: "consentiq_subject_id"), first)
        let uuid = try XCTUnwrap(UUID(uuidString: first))
        XCTAssertEqual(first, first.lowercased())
        XCTAssertEqual(uuid.uuidString.lowercased(), first)
        let version = first[first.index(first.startIndex, offsetBy: 14)]
        XCTAssertEqual(version, "4")
    }

    func testGenerateSubjectIdIsUnique() {
        let ids = Set((0..<50).map { _ in ConsentStorage.generateSubjectId() })
        XCTAssertEqual(ids.count, 50)
    }

    func testClearConsentLeavesSubjectId() {
        let id = storage.getOrCreateSubjectId()
        storage.saveConsent(["necessary": true])

        storage.clearConsent()

        XCTAssertNil(storage.loadConsent())
        XCTAssertEqual(storage.loadSubjectId(), id)
    }

    func testClearAllRemovesBothKeys() {
        _ = storage.getOrCreateSubjectId()
        storage.saveConsent(["necessary": true])

        storage.clearAll()

        XCTAssertNil(storage.loadConsent())
        XCTAssertNil(storage.loadSubjectId())
        XCTAssertNil(defaults.object(forKey: "consentiq_consent"))
        XCTAssertNil(defaults.object(forKey: "consentiq_subject_id"))
    }

    func testSuitesAreIsolated() {
        let otherSuite = "ai.iqworks.consentiq.tests.other.\(UUID().uuidString)"
        let other = ConsentStorage(userDefaults: UserDefaults(suiteName: otherSuite)!)
        defer { UserDefaults(suiteName: otherSuite)?.removePersistentDomain(forName: otherSuite) }

        storage.saveConsent(["necessary": true, "analytics": true])

        XCTAssertNil(other.loadConsent())
    }
}
