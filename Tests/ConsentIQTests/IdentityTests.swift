import XCTest
@testable import ConsentIQ

final class IdentityTests: XCTestCase {
    func testEmailsCompareByCase() {
        XCTAssertTrue(sameIdentifier("Alice@Example.com", " alice@example.com "))
        XCTAssertFalse(sameIdentifier("alice@example.com", "bob@example.com"))
    }

    func testPhonesCompareByDigitsOnlyWhenBothReadAsPhones() {
        XCTAssertTrue(sameIdentifier("+1 (202) 555-0143", "+12025550143"))
        XCTAssertFalse(sameIdentifier("+12025550143", "+12025550144"))
    }

    func testAnythingElseMustMatchExactly() {
        XCTAssertFalse(sameIdentifier("alice", "bob"))
        XCTAssertFalse(sameIdentifier("user-1", "User-1"))
        XCTAssertTrue(sameIdentifier("user-1", "user-1"))
    }

    func testSignedSubjectWithoutIdentityForSendsTheTokenAsIs() {
        let signed = signedSubject(identityToken: "v2.1.sig", identityFor: nil, identifier: "user-1")
        XCTAssertEqual(signed.subjectId, "user-1")
        XCTAssertEqual(signed.identityToken, "v2.1.sig")
    }

    func testSignedSubjectWithoutATokenSendsTheIdentifier() {
        let signed = signedSubject(identityToken: nil, identityFor: "a@x.com", identifier: "A@x.com")
        XCTAssertEqual(signed.subjectId, "A@x.com")
        XCTAssertNil(signed.identityToken)
    }
}
