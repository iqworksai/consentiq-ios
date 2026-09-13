#if canImport(UIKit)
import XCTest
import SwiftUI
import UIKit
@testable import ConsentIQ

@MainActor
final class SheetUITests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        suiteName = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func loadedSDK(autoShow: Bool, onOpen: (() -> Void)? = nil, onClose: (() -> Void)? = nil) async -> ConsentIQ {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON()))
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        let sdk = ConsentIQ(storage: ConsentStorage(userDefaults: defaults), urlSessionConfiguration: StubURLProtocol.sessionConfiguration)
        await sdk.initialize(ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            autoShow: autoShow,
            onOpen: onOpen,
            onClose: onClose
        ))
        return sdk
    }

    private func settle(_ seconds: TimeInterval = 0.1) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSheetContentLaysOutOnceConfigIsLoaded() async {
        let sdk = await loadedSDK(autoShow: true)

        let host = UIHostingController(rootView: ConsentSheetContent(consentIQ: sdk))
        host.view.frame = window.bounds
        window.rootViewController = host
        host.view.layoutIfNeeded()

        let size = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertGreaterThan(size.height, 120)
        XCTAssertLessThanOrEqual(size.width, 390)
    }

    func testSheetContentBeforeConfigShowsOnlyAPlaceholder() {
        let sdk = ConsentIQ(storage: ConsentStorage(userDefaults: defaults), urlSessionConfiguration: StubURLProtocol.sessionConfiguration)

        let host = UIHostingController(rootView: ConsentSheetContent(consentIQ: sdk))
        host.view.frame = window.bounds
        window.rootViewController = host
        host.view.layoutIfNeeded()

        XCTAssertNil(sdk.config)
        XCTAssertNotNil(host.view)
    }

    func testPresentSheetPresentsControllerAndFiresOnOpenOnce() async {
        var opened = 0
        let sdk = await loadedSDK(autoShow: false, onOpen: { opened += 1 })
        let root = window.rootViewController!

        sdk.presentSheet(from: root, animated: false)
        await settle()

        XCTAssertTrue(sdk.isSheetVisible)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(root.presentedViewController is ConsentSheetViewController)
        XCTAssertEqual(root.presentedViewController?.modalPresentationStyle, .pageSheet)
    }

    func testInteractiveDismissReportsOnClose() async throws {
        var closed = 0
        let sdk = await loadedSDK(autoShow: false, onClose: { closed += 1 })
        let root = window.rootViewController!
        sdk.presentSheet(from: root, animated: false)
        await settle()
        let controller = try XCTUnwrap(root.presentedViewController as? ConsentSheetViewController)
        let presentation = try XCTUnwrap(controller.presentationController)

        controller.presentationControllerDidDismiss(presentation)

        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(closed, 1)
    }

    // A logic test bundle has no app scene, so modal transitions never complete and the dismissal
    // itself cannot be observed; the callback contract around it can.
    func testProgrammaticHideFiresNothing() async {
        var closed = 0
        let sdk = await loadedSDK(autoShow: false, onClose: { closed += 1 })
        let root = window.rootViewController!
        sdk.presentSheet(from: root, animated: false)
        await settle()
        XCTAssertNotNil(root.presentedViewController)

        sdk.hideSheet()
        await settle()

        XCTAssertFalse(sdk.isSheetVisible)
        XCTAssertEqual(closed, 0)
    }

    func testConsentGateRendersOnlyWithConsent() async {
        let sdk = await loadedSDK(autoShow: false)
        let gate = ConsentGate(category: "analytics", consentIQ: sdk) { Text("tracked") }
        let host = UIHostingController(rootView: gate)
        host.view.frame = window.bounds
        window.rootViewController = host
        host.view.layoutIfNeeded()
        await settle()
        let hidden = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))

        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
        await sdk.updateConsent(["analytics": true])
        await settle()
        host.view.layoutIfNeeded()
        let shown = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))

        XCTAssertTrue(sdk.hasConsent("analytics"))
        XCTAssertGreaterThan(shown.height, hidden.height)
    }
}
#endif
