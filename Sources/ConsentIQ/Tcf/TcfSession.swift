import Foundation

enum TcfPageEvent {
    case message(String)
    case failed(code: String)
    case dismissedExternally
}

@MainActor
protocol TcfPageHosting: AnyObject {
    var onEvent: ((TcfPageEvent) -> Void)? { get set }
    func load()
    func start(_ options: TcfStartOptions)
    func present(reopen: Bool)
    func close()
}

typealias TcfPageFactory = @MainActor @Sendable (_ pageURL: URL, _ presenter: AnyObject?) -> (any TcfPageHosting)?

enum TcfOutcome {
    case current
    case decision(TcfDecision)
    case notApplicable
    case tcfOff
    case closed
    case failed(TcfError)
    case cancelled
}

@MainActor
final class TcfSession {
    nonisolated static let pagePath = "/api/public/tcf/mobile"
    static let defaultReadyTimeoutNanoseconds: UInt64 = 15_000_000_000
    // After start the page still fetches the config and the vendor list before it can answer.
    static let defaultAnswerTimeoutNanoseconds: UInt64 = 45_000_000_000

    nonisolated static func pageURL(apiURL: URL, propertyKey: String) -> URL {
        let base = apiURL.appendingPathComponent(pagePath)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "key", value: propertyKey)]
        return components?.url ?? base
    }

    let page: any TcfPageHosting
    private(set) var shown = false
    private let options: TcfStartOptions
    private let readyTimeoutNanoseconds: UInt64
    private let answerTimeoutNanoseconds: UInt64
    private let onShow: () -> Void
    private var continuation: CheckedContinuation<TcfOutcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var started = false
    private var failed = false

    init(
        page: any TcfPageHosting,
        options: TcfStartOptions,
        readyTimeoutNanoseconds: UInt64,
        answerTimeoutNanoseconds: UInt64,
        onShow: @escaping () -> Void
    ) {
        self.page = page
        self.options = options
        self.readyTimeoutNanoseconds = readyTimeoutNanoseconds
        self.answerTimeoutNanoseconds = answerTimeoutNanoseconds
        self.onShow = onShow
    }

    func run() async -> TcfOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            page.onEvent = { [weak self] event in self?.handle(event) }
            armTimeout(readyTimeoutNanoseconds)
            page.load()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func handle(_ event: TcfPageEvent) {
        switch event {
        case .failed(let code):
            finish(.failed(TcfError(code: code)))
        case .dismissedExternally:
            finish(.closed)
        case .message(let body):
            guard let parsed = TcfPageMessage(json: body) else { return }
            if !started {
                if case .ready = parsed.message {
                    started = true
                    armTimeout(answerTimeoutNanoseconds)
                    page.start(options)
                }
                return
            }
            // A frame inside the page can reach the bridge but cannot read the token.
            guard parsed.token == options.token else { return }
            receive(parsed.message)
        }
    }

    private func receive(_ message: TcfMessage) {
        switch message {
        case .show where !shown:
            shown = true
            cancelTimeout()
            page.present(reopen: options.reopen)
            if !failed {
                onShow()
            }
        case .current where !shown:
            finish(.current)
        case .decision(let decision):
            finish(.decision(decision))
        case .notApplicable:
            finish(.notApplicable)
        case .closed where shown:
            finish(.closed)
        case .error(let code):
            finish(code == TcfError.tcfOff ? .tcfOff : .failed(TcfError(code: code ?? "unknown")))
        default:
            break
        }
    }

    private func armTimeout(_ nanoseconds: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(.failed(TcfError(code: TcfError.timedOut)))
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func finish(_ outcome: TcfOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        if case .failed = outcome {
            failed = true
        }
        cancelTimeout()
        page.onEvent = nil
        continuation.resume(returning: outcome)
    }
}
