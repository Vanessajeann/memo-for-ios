import Foundation

/// Ported constants from Android v3.2.0-beta1. No background execution guarantee.
public enum RecordingPolicy {
    public static let stallSeconds: TimeInterval = 60
    public static let maxRetries = 8
    public static func delay(attempt: Int) -> TimeInterval {
        min(30, 2 * pow(2, Double(min(4, max(0, attempt - 1)))))
    }
    public static func stalled(now: TimeInterval, lastProgress: TimeInterval, capturing: Bool, stopping: Bool) -> Bool {
        capturing && !stopping && now - lastProgress >= stallSeconds
    }
    public static func retry(wanted: Bool, attempts: Int, reconnect: Bool, online: Bool, logs: String) -> Bool {
        guard wanted, attempts < maxRetries else { return false }
        let s = logs.lowercased()
        let permanent = ["no space left", "permission denied", "read-only file system", "malformed aac", "unrecognized option", "unsatisfiedlinkerror"]
        guard !permanent.contains(where: { s.contains($0) }) else { return false }
        if s.range(of: #"(?:http[^\n]*|server returned )(?:401|403|404)"#, options: .regularExpression) != nil { return false }
        if reconnect || !online { return true }
        let transient = ["timed out", "timeout", "connection reset", "connection refused", "network is unreachable", "network unreachable", "broken pipe", "input/output error", "error opening input", "failed to open segment"]
        return transient.contains(where: { s.contains($0) }) || s.range(of: #"(?:http[^\n]*|server returned )5[0-9]{2}"#, options: .regularExpression) != nil
    }
}
