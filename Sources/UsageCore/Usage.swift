import Foundation

public let refreshInterval: TimeInterval = 120

public struct UsageWindow: Equatable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ResetCredits: Equatable {
    public var available: Int
    public var paused: Int
    public var soonestExpiry: Date?
    public init(available: Int, paused: Int, soonestExpiry: Date?) {
        self.available = available
        self.paused = paused
        self.soonestExpiry = soonestExpiry
    }
}

public struct ProviderUsage: Equatable {
    public var plan: String?
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    public var fableWeekly: UsageWindow?
    public var resets: ResetCredits?
    public init(plan: String? = nil, fiveHour: UsageWindow? = nil, weekly: UsageWindow? = nil,
                fableWeekly: UsageWindow? = nil, resets: ResetCredits? = nil) {
        self.plan = plan
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fableWeekly = fableWeekly
        self.resets = resets
    }
}

public enum UsageError: Error, Equatable {
    case authExpired(String)
    case failed(String)

    public var message: String {
        switch self {
        case .authExpired(let m), .failed(let m): return m
        }
    }
}

public enum UsageLevel: Equatable { case ok, warn, critical }

public func usageLevel(_ percent: Double) -> UsageLevel {
    if percent < 70 { return .ok }
    if percent < 90 { return .warn }
    return .critical
}

private func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

public func formatCountdown(to: Date, now: Date) -> String {
    let interval = to.timeIntervalSince(now)
    guard interval > 0 else { return "now" }
    let total = Int(interval)
    if total < 3600 { return "\(total / 60)m \(pad2(total % 60))s" }
    if total < 86400 { return "\(total / 3600)h \(pad2((total % 3600) / 60))m" }
    return "\(total / 86400)d \((total % 86400) / 3600)h"
}

public func formatWeeklyReset(to: Date, now: Date, timeZone: TimeZone = .current) -> String {
    let countdown = formatCountdown(to: to, now: now)
    if countdown == "now" { return countdown }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "EEE HH:mm"
    return countdown + " (" + f.string(from: to) + ")"
}

public func formatElapsed(since: Date, now: Date) -> String {
    let s = Int(max(0, now.timeIntervalSince(since)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

public func currentWindow(_ window: UsageWindow?, now: Date) -> (window: UsageWindow?, resetPassed: Bool) {
    guard let window else { return (nil, false) }
    if let r = window.resetsAt, r <= now { return (UsageWindow(usedPercent: 0, resetsAt: nil), true) }
    return (window, false)
}

public struct ProviderSnapshot: Equatable {
    public var usage: ProviderUsage?
    public var error: UsageError?
    public var stale: Bool
    public init(usage: ProviderUsage?, error: UsageError?, stale: Bool) {
        self.usage = usage
        self.error = error
        self.stale = stale
    }
}

public func nextSnapshot(previous: ProviderSnapshot?, result: Result<ProviderUsage, UsageError>) -> ProviderSnapshot {
    switch result {
    case .success(let usage):
        return ProviderSnapshot(usage: usage, error: nil, stale: false)
    case .failure(let error):
        if case .authExpired = error { return ProviderSnapshot(usage: nil, error: error, stale: false) }
        let kept = previous?.usage
        return ProviderSnapshot(usage: kept, error: error, stale: kept != nil)
    }
}

public func codexChildPATH(codexPath: String, inheritedPATH: String?) -> String {
    let dir = (codexPath as NSString).deletingLastPathComponent
    let inherited = (inheritedPATH?.isEmpty == false) ? inheritedPATH! : "/usr/bin:/bin:/usr/sbin:/sbin"
    return [dir, "/opt/homebrew/bin", "/usr/local/bin", inherited].filter { !$0.isEmpty }.joined(separator: ":")
}

private let iso8601Pattern = try! NSRegularExpression(
    pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{0,9}))?(Z|[+-]\d{2}:\d{2})$"#)

public func parseISO8601(_ s: String) -> Date? {
    let ns = s as NSString
    guard let m = iso8601Pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    func group(_ i: Int) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
    guard let year = Int(group(1)!), let month = Int(group(2)!), let day = Int(group(3)!),
          let hour = Int(group(4)!), let minute = Int(group(5)!), let second = Int(group(6)!),
          (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
    else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    guard let base = cal.date(from: DateComponents(year: year, month: month, day: day,
                                                   hour: hour, minute: minute, second: second))
    else { return nil }
    var fraction = 0.0
    if let digits = group(7), !digits.isEmpty { fraction = Double("0." + digits) ?? 0 }
    var offset = 0
    let zone = group(8)!
    if zone != "Z" {
        let sign = zone.hasPrefix("-") ? -1 : 1
        let parts = zone.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let mm = Int(parts[1]) else { return nil }
        offset = sign * (h * 3600 + mm * 60)
    }
    return base.addingTimeInterval(fraction - Double(offset))
}

// MARK: - Shared JSON helpers

/// A finite JSON number (never a JSON boolean), or nil for any other type.
func jsonNumber(_ value: Any?) -> Double? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}

/// True when a JSON value is absent or explicitly null.
func jsonIsNull(_ value: Any?) -> Bool {
    value == nil || value is NSNull
}

/// A JSON boolean, or nil for any other type.
func jsonBool(_ value: Any?) -> Bool? {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}

/// A required JSON number: wrong type -> `.failed(message)`.
func requireNumber(_ value: Any?, _ message: String) throws -> Double {
    guard let d = jsonNumber(value) else { throw UsageError.failed(message) }
    return d
}
