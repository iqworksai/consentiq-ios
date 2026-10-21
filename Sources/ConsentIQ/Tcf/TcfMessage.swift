import Foundation

public struct TcfError: Error, LocalizedError, Equatable, Sendable {
    public static let timedOut = "timeout"
    public static let pageLoadFailed = "page-load-failed"
    public static let startFailed = "start-failed"
    public static let invalidDecision = "invalid-decision"
    public static let noPresenter = "no-presenter"
    public static let unavailable = "unavailable"
    public static let tcfOff = "tcf-off"

    public let code: String

    public init(code: String) {
        self.code = code
    }

    public var errorDescription: String? { "TCF screen failed (\(code))" }
}

struct TcfDecision {
    enum Scope: String {
        case acceptAll = "all"
        case rejectAll = "none"
        case custom
    }

    let keys: [String: Any]
    let stored: [String: Any]?
    let consent: ConsentState?
    let scope: Scope?
}

enum TcfMessage {
    case ready
    case current
    case show
    case decision(TcfDecision)
    case notApplicable
    case closed
    case error(code: String?)
}

struct TcfPageMessage {
    let message: TcfMessage
    let token: String?

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["type"] as? String,
              let message = Self.message(type: type, object: object) else { return nil }
        self.message = message
        token = object["token"] as? String
    }

    private static func message(type: String, object: [String: Any]) -> TcfMessage? {
        switch type {
        case "ready": return .ready
        case "current": return .current
        case "show": return .show
        case "not-applicable": return .notApplicable
        case "closed": return .closed
        case "error": return .error(code: object["code"] as? String)
        case "decision":
            guard let keys = object["keys"] as? [String: Any] else { return .error(code: TcfError.invalidDecision) }
            return .decision(TcfDecision(
                keys: keys,
                stored: object["stored"] as? [String: Any],
                consent: consent(object["consent"]),
                scope: (object["scope"] as? String).flatMap(TcfDecision.Scope.init(rawValue:))
            ))
        default:
            return nil
        }
    }

    private static func consent(_ raw: Any?) -> ConsentState? {
        guard let map = raw as? [String: Any] else { return nil }
        var consent: ConsentState = [:]
        for (category, value) in map {
            if let granted = value as? Bool {
                consent[category] = granted
            }
        }
        return consent
    }
}

struct TcfStartOptions {
    let subjectId: String
    let stored: [String: Any]?
    let consent: ConsentState
    let reopen: Bool
    let token: String

    var arguments: [String: Any] {
        [
            "subjectId": subjectId,
            "stored": stored ?? NSNull(),
            "consent": consent,
            "reopen": reopen,
            "token": token,
        ]
    }
}
