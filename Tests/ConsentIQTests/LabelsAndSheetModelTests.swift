import XCTest
@testable import ConsentIQ

final class LabelsAndSheetModelTests: XCTestCase {
    private var config: PropertyConfig!

    override func setUpWithError() throws {
        try super.setUpWithError()
        config = try Fixtures.decodeConfig()
    }

    func testRegionalTagFallsBackToBaseLanguageLabels() {
        let labels = config.labels(for: "ar-EG")
        XCTAssertEqual(labels, config.labels["ar"])
        XCTAssertEqual(labels.acceptAll, "قبول الكل")
        XCTAssertTrue(config.isRTL("ar-EG"))
        XCTAssertTrue(config.isRTL("AR"))
    }

    func testExactTagWins() {
        XCTAssertEqual(config.labels(for: "ar"), config.labels["ar"])
        XCTAssertEqual(config.labels(for: "en"), config.labels["en"])
    }

    func testUnknownLanguageFallsBackToEnglishAndLTR() {
        XCTAssertEqual(config.labels(for: "hi"), config.labels["en"])
        XCTAssertEqual(config.labels(for: "en-GB"), config.labels["en"])
        XCTAssertFalse(config.isRTL("hi"))
        XCTAssertFalse(config.isRTL("en-GB"))
    }

    func testRTLListDrivesDirectionForEveryListedLanguage() {
        for code in ["ar", "ur", "ks", "sd", "ur-PK"] {
            XCTAssertTrue(config.isRTL(code), code)
        }
        XCTAssertFalse(config.isRTL("he"), "only the server's list counts")
    }

    func testEmptyLabelsYieldBlankLabelsRatherThanCrashing() throws {
        let bare = try Fixtures.decodeConfig(#"{"property":{"id":"p"}}"#)
        XCTAssertEqual(bare.labels(for: "en"), BannerLabels())
        XCTAssertFalse(bare.isRTL("ar"))
    }

    func testTranslationsResolveLikeLabels() {
        XCTAssertEqual(config.translations(for: "ar-EG")?.bannerDescription, "نستخدم ملفات تعريف الارتباط.")
        XCTAssertEqual(config.translations(for: "fr")?.bannerDescription, "We use cookies.")
        XCTAssertEqual(config.translations(for: "en")?.categories["analytics"]?.title, "Analytics")
    }

    func testNoticeURLAppendsLangWithCorrectSeparator() throws {
        let withQuery = try XCTUnwrap(config.banner?.noticeURL(language: "ar-EG"))
        XCTAssertEqual(withQuery.absoluteString, "https://consent.example.test/api/public/privacy/pk_test_property?notice=n-1&lang=ar-EG")

        var banner = try XCTUnwrap(config.banner)
        banner.noticeUrl = "https://example.test/notice"
        XCTAssertEqual(banner.noticeURL(language: "en")?.absoluteString, "https://example.test/notice?lang=en")

        banner.noticeUrl = "https://example.test/notice?x=1#top"
        XCTAssertEqual(banner.noticeURL(language: "en")?.absoluteString, "https://example.test/notice?x=1&lang=en#top")

        banner.noticeUrl = nil
        XCTAssertNil(banner.noticeURL(language: "en"))

        banner.noticeUrl = "javascript:alert(1)"
        XCTAssertNil(banner.noticeURL(language: "en"))

        banner.noticeUrl = "/relative/path"
        XCTAssertNil(banner.noticeURL(language: "en"))
    }

    func testSheetSelectionInitialisesFromConsentThenDefaultState() {
        let selection = SheetSelection(consent: ["necessary": true, "analytics": true], categories: config.categories)

        XCTAssertEqual(selection.values["analytics"], true)
        XCTAssertEqual(selection.values["marketing"], false, "unknown category takes defaultState")
        XCTAssertEqual(selection.values["functional"], true, "unknown category takes defaultState")
        XCTAssertEqual(selection.values["necessary"], true)

        let necessary = config.categories[0]
        let analytics = config.categories[1]
        XCTAssertTrue(selection.isOn(necessary))
        XCTAssertTrue(selection.isOn(analytics))
    }

    func testSheetSelectionKeepsRequiredOnAndNecessaryTrue() {
        var selection = SheetSelection(consent: ["necessary": false, "analytics": false], categories: config.categories)
        XCTAssertEqual(selection.values["necessary"], true)

        selection.set("necessary", false)
        selection.set("analytics", true)

        XCTAssertEqual(selection.values["necessary"], true)
        XCTAssertEqual(selection.values["analytics"], true)
        XCTAssertTrue(selection.isOn(config.categories[0]))
    }

    func testHexColorParsing() {
        XCTAssertEqual(HexColor.parse("#f97316"), HexColor(red: 0xF9, green: 0x73, blue: 0x16))
        XCTAssertEqual(HexColor.parse("112233"), HexColor(red: 0x11, green: 0x22, blue: 0x33))
        XCTAssertEqual(HexColor.parse("#FFF"), HexColor(red: 0xFF, green: 0xFF, blue: 0xFF))
        XCTAssertEqual(HexColor.parse(" #abc "), HexColor(red: 0xAA, green: 0xBB, blue: 0xCC))
        XCTAssertNil(HexColor.parse(nil))
        XCTAssertNil(HexColor.parse(""))
        XCTAssertNil(HexColor.parse("#12345"))
        XCTAssertNil(HexColor.parse("#gggggg"))
        XCTAssertNil(HexColor.parse("orange"))
        XCTAssertEqual(HexColor.defaultPrimary, HexColor.parse("#f97316"))
    }

    func testForcingNecessary() {
        XCTAssertEqual(["analytics": true].forcingNecessary(), ["analytics": true, "necessary": true])
        XCTAssertEqual(["necessary": false].forcingNecessary(), ["necessary": true])
    }
}
