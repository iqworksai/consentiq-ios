import Foundation
import os

struct ConsentIQLogger {
    static let prefix = "[ConsentIQ]"
    static let captchaWarning = "This property requires a captcha, which mobile SDKs cannot satisfy. "
        + "Turn off \"Require captcha\" for this property in the ConsentIQ dashboard."

    private static let logger = Logger(subsystem: "ai.iqworks.consentiq", category: "sdk")

    var debugEnabled: Bool
    var sink: ((String) -> Void)?

    init(debugEnabled: Bool = false, sink: ((String) -> Void)? = nil) {
        self.debugEnabled = debugEnabled
        self.sink = sink
    }

    func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "\(Self.prefix) \(message())"
        Self.logger.debug("\(line, privacy: .private)")
        sink?(line)
    }

    func warning(_ message: String) {
        let line = "\(Self.prefix) \(message)"
        Self.logger.warning("\(line, privacy: .public)")
        sink?(line)
    }

    func error(_ message: String) {
        let line = "\(Self.prefix) \(message)"
        Self.logger.error("\(line, privacy: .public)")
        sink?(line)
    }
}
