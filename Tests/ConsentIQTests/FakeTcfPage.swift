import Foundation
@testable import ConsentIQ

@MainActor
final class FakeTcfPage: TcfPageHosting {
    static let ready = #"{"type":"ready"}"#
    static let show = #"{"type":"show"}"#
    static let current = #"{"type":"current"}"#
    static let closed = #"{"type":"closed"}"#
    static let notApplicable = #"{"type":"not-applicable"}"#

    var onEvent: ((TcfPageEvent) -> Void)?
    var onLoad: [String] = [FakeTcfPage.ready]
    var onStart: [String] = []
    var onPresent: [String] = []
    var failOnLoad: String?
    var failOnPresent: String?
    var afterPresent: (() -> Void)?

    private(set) var requestedURLs: [URL] = []
    private(set) var presenters: [AnyObject?] = []
    private(set) var loadCount = 0
    private(set) var startOptions: [TcfStartOptions] = []
    private(set) var presented: [Bool] = []
    private(set) var closeCount = 0

    func factory(available: Bool = true) -> TcfPageFactory {
        { [self] url, presenter in
            requestedURLs.append(url)
            presenters.append(presenter)
            guard available else { return nil }
            return self
        }
    }

    var token: String? { startOptions.last?.token }

    func send(_ json: String) {
        guard let token, var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            sendRaw(json)
            return
        }
        object["token"] = object["token"] ?? token
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(json.utf8)
        sendRaw(String(bytes: data, encoding: .utf8) ?? json)
    }

    func sendRaw(_ json: String) {
        onEvent?(.message(json))
    }

    func dismissExternally() {
        onEvent?(.dismissedExternally)
    }

    func load() {
        loadCount += 1
        if let failOnLoad {
            onEvent?(.failed(code: failOnLoad))
            return
        }
        onLoad.forEach(send)
    }

    func start(_ options: TcfStartOptions) {
        startOptions.append(options)
        onStart.forEach(send)
    }

    func present(reopen: Bool) {
        presented.append(reopen)
        if let failOnPresent {
            onEvent?(.failed(code: failOnPresent))
            return
        }
        onPresent.forEach(send)
        afterPresent?()
    }

    func close() {
        closeCount += 1
    }
}
