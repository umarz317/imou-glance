import os

/// Stream lifecycle events, readable with `log stream --predicate 'subsystem == "local.imou.peek"'`.
/// Logs camera ids by suffix only and never logs credentials or stream URLs.
enum StreamLog {
    static let logger = Logger(subsystem: "local.imou.peek", category: "stream")

    static func camera(_ deviceId: String) -> String { "…" + String(deviceId.suffix(4)) }
}
