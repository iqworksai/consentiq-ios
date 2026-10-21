import XCTest
@testable import ConsentIQ

@MainActor
class TcfSDKTestCase: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var storage: ConsentStorage!
    var page: FakeTcfPage!
    var logLines: [String] = []
    var events: [String] = []
    var errors: [Error] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stubFallback(StubResponse(json: Fixtures.noConsentJSON))
        StubURLProtocol.stub("POST", Fixtures.consentPath, StubResponse(json: Fixtures.submitResultJSON))
        suiteName = "ai.iqworks.consentiq.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storage = ConsentStorage(userDefaults: defaults)
        page = FakeTcfPage()
        logLines = []
        events = []
        errors = []
        clearStandardTcfKeys()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        clearStandardTcfKeys()
        super.tearDown()
    }

    func makeSDK(pageAvailable: Bool = true) -> ConsentIQ {
        let sdk = ConsentIQ(
            storage: storage,
            urlSessionConfiguration: StubURLProtocol.sessionConfiguration,
            captchaProviderFactory: FakeCaptchaProvider().factory(),
            tcfPageFactory: page.factory(available: pageAvailable)
        )
        sdk.logSink = { [weak self] line in self?.logLines.append(line) }
        return sdk
    }

    func stubConfig(tcf: String?) {
        StubURLProtocol.stub("GET", Fixtures.configPath, StubResponse(json: Fixtures.configJSON(tcf: tcf)))
    }

    func config(autoShow: Bool = true) -> ConsentIQConfig {
        ConsentIQConfig(
            propertyKey: Fixtures.propertyKey,
            apiURL: Fixtures.apiURL,
            autoShow: autoShow,
            debug: true,
            onConsentChange: { [weak self] consent, _ in self?.events.append("change:\(consent["analytics"] == true)") },
            onOpen: { [weak self] in self?.events.append("open") },
            onAccept: { [weak self] _ in self?.events.append("accept") },
            onReject: { [weak self] _ in self?.events.append("reject") },
            onSave: { [weak self] _ in self?.events.append("save") },
            onClose: { [weak self] in self?.events.append("close") },
            onError: { [weak self] error in self?.errors.append(error) }
        )
    }

    func initialize(_ sdk: ConsentIQ, autoShow: Bool = true) async {
        await sdk.initialize(config(autoShow: autoShow))
        await sdk.tcfTask?.value
    }

    func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    var standard: UserDefaults { .standard }

    var errorCodes: [String] {
        errors.compactMap { ($0 as? TcfError)?.code }
    }
}
