import Foundation
import Testing
@testable import UsageCore

private let base = Date(timeIntervalSince1970: 2_000_000)

@Test func countdownAndElapsedFormatting() {
    #expect(formatCountdown(to: base.addingTimeInterval(1), now: base) == "0m 01s")
    #expect(formatCountdown(to: base.addingTimeInterval(3599), now: base) == "59m 59s")
    #expect(formatCountdown(to: base.addingTimeInterval(2 * 3600 + 13 * 60 + 59), now: base) == "2h 13m")
    #expect(formatCountdown(to: base.addingTimeInterval(86400), now: base) == "1d 0h")
    #expect(formatCountdown(to: base.addingTimeInterval(-60), now: base) == "now")
    #expect(formatElapsed(since: base, now: base.addingTimeInterval(59)) == "59s")
    #expect(formatElapsed(since: base, now: base.addingTimeInterval(60)) == "1m")
    #expect(formatElapsed(since: base, now: base.addingTimeInterval(86400 * 3 + 5)) == "3d")
}

@Test func weeklyResetIncludesWeekdayAndTime() {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let now = Date(timeIntervalSince1970: 1_791_000_000)          // 2026-10-03T04:00:00Z
    let reset = Date(timeIntervalSince1970: 1_791_000_000 + 2 * 86400 + 3 * 3600 + 30 * 60)
    // Reset at 2026-10-05T07:30Z = Mon 16:30 in Tokyo.
    #expect(formatWeeklyReset(to: reset, now: now, timeZone: tokyo) == "2d 3h (Mon 16:30)")
    #expect(formatWeeklyReset(to: now, now: now, timeZone: tokyo) == "now")
}

@Test func levelsAndPassedResets() {
    #expect(usageLevel(0) == .ok)
    #expect(usageLevel(75) == .warn)
    #expect(usageLevel(100) == .critical)
    let w = UsageWindow(usedPercent: 50, resetsAt: base)
    let passed = currentWindow(w, now: base)
    #expect(passed.resetPassed && passed.window == UsageWindow(usedPercent: 0, resetsAt: nil))
    let open = UsageWindow(usedPercent: 50, resetsAt: nil)
    #expect(currentWindow(open, now: base).window == open)
    #expect(!currentWindow(open, now: base).resetPassed)
}

@Test func snapshotsKeepLastGoodUnlessAuthExpired() {
    let good = ProviderUsage(plan: "plus", weekly: UsageWindow(usedPercent: 40, resetsAt: nil))
    let ok = nextSnapshot(previous: nil, result: .success(good))
    let failed = nextSnapshot(previous: ok, result: .failure(.failed("offline")))
    #expect(failed.usage == good && failed.stale && failed.error == .failed("offline"))
    let stillStale = nextSnapshot(previous: failed, result: .failure(.failed("again")))
    #expect(stillStale.usage == good && stillStale.stale)
    let auth = nextSnapshot(previous: failed, result: .failure(.authExpired("x /login")))
    #expect(auth.usage == nil && !auth.stale)
    let recovered = nextSnapshot(previous: auth, result: .success(good))
    #expect(recovered == ProviderSnapshot(usage: good, error: nil, stale: false))
}

@Test func codexChildPathPrefersCodexDirectory() {
    #expect(codexChildPATH(codexPath: "/usr/local/bin/codex", inheritedPATH: "/a:/b")
            == "/usr/local/bin:/opt/homebrew/bin:/usr/local/bin:/a:/b")
    #expect(codexChildPATH(codexPath: "/opt/homebrew/bin/codex", inheritedPATH: nil)
            .hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin"))
}

@Test func iso8601Variants() {
    #expect(parseISO8601("2026-10-03T00:00:00Z") == Date(timeIntervalSince1970: 1_790_985_600))
    #expect(parseISO8601("2026-10-03T02:00:00+02:00") == Date(timeIntervalSince1970: 1_790_985_600))
    #expect(parseISO8601("2026-10-02T19:30:00-04:30") == Date(timeIntervalSince1970: 1_790_985_600))
    let frac = parseISO8601("2026-10-03T00:00:00.5Z")!.timeIntervalSince1970
    #expect(abs(frac - 1_790_985_600.5) < 0.001)
    #expect(parseISO8601("2026-10-03 00:00:00Z") == nil)
    #expect(parseISO8601("garbage") == nil)
}

@Test func codexParsesProbeFixture() throws {
    let out = """
    {"method":"remoteControl/status/changed","params":{}}
    {"id":1,"result":{"userAgent":"codex"}}
    {"method":"account/updated","params":{}}
    {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":76,"windowDurationMins":300,"resetsAt":1791018939},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1791605739},"credits":{},"planType":"plus"},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"a","status":"available","expiresAt":1792698897},{"id":"b","status":"available","expiresAt":1793293124}]},"accountId":"x","rateLimitUpsell":null}}
    """
    let u = try Codex.parse(stdout: out)
    #expect(u.plan == "plus")
    #expect(u.fiveHour == UsageWindow(usedPercent: 76, resetsAt: Date(timeIntervalSince1970: 1_791_018_939)))
    #expect(u.weekly == UsageWindow(usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_791_605_739)))
    #expect(u.resets == ResetCredits(available: 2, paused: 0, soonestExpiry: Date(timeIntervalSince1970: 1_792_698_897)))
    #expect(u.fableWeekly == nil)
}

@Test func codexWindowsWithoutDurationUsePosition() throws {
    let u = try Codex.parse(stdout: #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5},"secondary":{"usedPercent":6}}}}"#)
    #expect(u.fiveHour?.usedPercent == 5 && u.weekly?.usedPercent == 6 && u.resets == nil && u.plan == nil)
    #expect(throws: UsageError.failed("Codex: no rate-limit response")) { try Codex.parse(stdout: "") }
    #expect(throws: UsageError.failed("Codex: " + String(repeating: "x", count: 120))) {
        try Codex.parse(stdout: #"{"id":2,"error":{"message":"\#(String(repeating: "x", count: 200))"}}"#)
    }
}

@Test func claudeParsesWindowsAndGrants() throws {
    let now = Date(timeIntervalSince1970: 1_790_985_600)   // 2026-10-03T00:00:00Z
    let body = Data(#"""
    {"five_hour":{"utilization":55,"resets_at":"2026-10-03T03:00:00.000+00:00"},
     "seven_day":{"utilization":80.25,"resets_at":"2026-10-08T00:00:00Z"},
     "seven_day_overage_included":{"utilization":95,"resets_at":"bogus"},
     "seven_day_opus":{"utilization":1,"resets_at":null},
     "cedar_ember":{"grants":[
       {"resets_left":2,"ends_at":"2026-10-20T00:00:00Z","paused":false,"clears":["seven_day_overage_included"]},
       {"resets_left":1,"ends_at":"2026-10-10T00:00:00Z","paused":false,"clears":["seven_day","five_hour"]},
       {"resets_left":3,"paused":true},
       {"resets_left":8,"ends_at":"2026-10-02T23:59:59Z","paused":false,"clears":["seven_day"]},
       {"resets_left":6,"ends_at":"2026-10-11T00:00:00Z","paused":false,"clears":["five_hour"]}
     ]}}
    """#.utf8)
    let u = try Claude.parse(status: 200, body: body, plan: "pro", now: now)
    #expect(u.plan == "pro")
    #expect(u.fiveHour == UsageWindow(usedPercent: 55, resetsAt: Date(timeIntervalSince1970: 1_790_996_400)))
    #expect(u.weekly == UsageWindow(usedPercent: 80.25, resetsAt: Date(timeIntervalSince1970: 1_791_417_600)))
    #expect(u.fableWeekly == UsageWindow(usedPercent: 95, resetsAt: nil))
    #expect(u.resets == ResetCredits(available: 3, paused: 3, soonestExpiry: Date(timeIntervalSince1970: 1_791_590_400)))
}

@Test func claudePartialBodyAndErrors() throws {
    let partial = try Claude.parse(status: 200, body: Data(#"{"seven_day":{"utilization":3},"cedar_ember":null}"#.utf8), plan: nil)
    #expect(partial.fiveHour == nil && partial.weekly == UsageWindow(usedPercent: 3, resetsAt: nil) && partial.resets == nil)
    #expect(throws: UsageError.authExpired(Claude.loginHint)) { try Claude.parse(status: 401, body: Data("secret".utf8), plan: nil) }
    #expect(throws: UsageError.authExpired(Claude.loginHint)) { try Claude.parse(status: 403, body: Data(), plan: nil) }
    #expect(throws: UsageError.failed("Claude: HTTP 500")) { try Claude.parse(status: 500, body: Data("secret".utf8), plan: nil) }
    #expect(throws: UsageError.failed("Claude: bad response")) { try Claude.parse(status: 200, body: Data("\"x\"".utf8), plan: nil) }
    #expect(throws: UsageError.self) { try Claude.parse(status: 200, body: Data(#"{"seven_day":{"utilization":true}}"#.utf8), plan: nil) }
}

@Test func keychainJSONAndRequest() throws {
    let json = Data(#"{"claudeAiOauth":{"accessToken":"t-1","subscriptionType":"max","rateLimitTier":"x"}}"#.utf8)
    #expect(try Claude.accessToken(fromKeychainJSON: json) == "t-1")
    #expect(Claude.subscriptionType(fromKeychainJSON: json) == "max")
    #expect(Claude.subscriptionType(fromKeychainJSON: Data("nope".utf8)) == nil)
    #expect(throws: UsageError.authExpired(Claude.loginHint)) { try Claude.accessToken(fromKeychainJSON: Data("[]".utf8)) }
    let req = Claude.usageRequest(accessToken: "t-1")
    #expect(req.httpMethod == "GET")
    #expect(req.value(forHTTPHeaderField: "User-Agent") == Claude.userAgent(version: Claude.claudeCodeVersion()))
    #expect(req.timeoutInterval == 15)
}

@Test func codexFetchAgainstFakeServer() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagecore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let script = dir.appendingPathComponent("codex")
    try """
    #!/bin/bash
    [ "$1" = "app-server" ] || exit 3
    while IFS= read -r line; do
      case "$line" in
        *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
        *rateLimits/read*)
          echo '{"method":"account/updated","params":{}}'
          echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":41,"windowDurationMins":300},"planType":"pro"},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}' ;;
      esac
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let u = try await Codex.fetch(executable: script.path, timeout: 5)
    #expect(u.plan == "pro" && u.fiveHour?.usedPercent == 41 && u.weekly == nil)
    #expect(u.resets == ResetCredits(available: 0, paused: 0, soonestExpiry: nil))

    await #expect(throws: UsageError.failed("Codex CLI not found")) {
        try await Codex.fetch(executable: dir.appendingPathComponent("missing").path)
    }
}

@Test func claudeFableComesFromLiveLimitsArray() throws {
    let body = Data(#"""
    {"five_hour":{"utilization":1.0,"resets_at":"2026-10-03T12:10:00.248348+00:00"},
     "seven_day":{"utilization":77.0,"resets_at":"2026-10-07T16:00:00.248374+00:00"},
     "seven_day_opus":null,
     "limits":[
       {"kind":"session","group":"session","percent":1,"resets_at":"2026-10-03T12:10:00.248348+00:00","scope":null},
       {"kind":"weekly_all","group":"weekly","percent":77,"resets_at":"2026-10-07T16:00:00.248374+00:00","scope":null},
       {"kind":"weekly_scoped","group":"weekly","percent":91,"severity":"critical","resets_at":"2026-10-07T16:00:00.248583+00:00",
        "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}],
     "cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}
    """#.utf8)
    let usage = try Claude.parse(status: 200, body: body, plan: "max", now: base)
    #expect(usage.fiveHour?.usedPercent == 1 && usage.weekly?.usedPercent == 77)
    #expect(usage.fableWeekly?.usedPercent == 91)
    #expect(usage.fableWeekly?.resetsAt != nil)
    #expect(usage.resets == ResetCredits(available: 0, paused: 0, soonestExpiry: nil))
    // Another model's scoped limit is not Fable; a malformed Fable percent is an error.
    let other = #"[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]"#
    #expect(try Claude.fableWindow(fromLimits: JSONSerialization.jsonObject(with: Data(other.utf8))) == nil)
    let bad = #"[{"kind":"weekly_scoped","percent":"91","scope":{"model":{"display_name":"Fable"}}}]"#
    #expect(throws: UsageError.self) { try Claude.fableWindow(fromLimits: JSONSerialization.jsonObject(with: Data(bad.utf8))) }
}

@Test func claudeUserAgentUsesInstalledClaudeCodeVersion() throws {
    #expect(Claude.userAgent(version: "2.3.4") == "claude-cli/2.3.4 (external, cli)")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ua-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let native = dir.appendingPathComponent("claude").path
    try FileManager.default.createSymbolicLink(atPath: native, withDestinationPath: "/x/versions/3.0.12")
    #expect(Claude.claudeCodeVersion(launcher: native) == "3.0.12")
    let npm = dir.appendingPathComponent("claude-npm").path
    try FileManager.default.createSymbolicLink(atPath: npm, withDestinationPath: "../lib/node_modules/@anthropic-ai/claude-code/cli.js")
    #expect(Claude.claudeCodeVersion(launcher: npm) == Claude.fallbackClaudeCodeVersion)
    #expect(Claude.claudeCodeVersion(launcher: dir.appendingPathComponent("missing").path) == Claude.fallbackClaudeCodeVersion)
}
