import Foundation

public enum Claude {
    public static let loginHint = "Claude login expired — run `claude` in Terminal, then /login"
    static let noKeychainItem = "No Claude Code login in Keychain — run `claude`, then /login"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static let maxBodyBytes = 1 << 20
    static let maxKeychainBytes = 64 << 10

    // MARK: Keychain

    private static func oauthObject(_ json: Data) -> [String: Any]? {
        let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        return root?["claudeAiOauth"] as? [String: Any]
    }

    public static func accessToken(fromKeychainJSON json: Data) throws -> String {
        guard let token = oauthObject(json)?["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.authExpired(loginHint)
        }
        return token
    }

    public static func subscriptionType(fromKeychainJSON json: Data) -> String? {
        oauthObject(json)?["subscriptionType"] as? String
    }

    /// Reads the Claude Code credentials item with `security find-generic-password -w` (read-only).
    public static func readKeychain(tool: String = "/usr/bin/security", timeout: TimeInterval = 5) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        let box = Box()
        let readerDone = DispatchSemaphore(value: 0)

        do {
            try process.run()
        } catch {
            throw UsageError.failed("Claude: cannot run Keychain tool")
        }

        // Read stdout off this thread until EOF, keeping at most maxKeychainBytes.
        DispatchQueue.global(qos: .utility).async {
            let handle = out.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.lock.lock()
                if box.data.count < maxKeychainBytes {
                    box.data.append(chunk.prefix(maxKeychainBytes - box.data.count))
                }
                box.lock.unlock()
            }
            readerDone.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateTree(process)
            throw UsageError.failed("Claude: Keychain read timed out")
        }
        _ = readerDone.wait(timeout: .now() + 1)
        box.lock.lock()
        let data = box.data
        box.lock.unlock()

        guard process.terminationStatus == 0 else { throw UsageError.authExpired(noKeychainItem) }
        return data
    }

    // MARK: HTTP

    public static func usageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent(version: claudeCodeVersion()), forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Claude reports reset credits (`cedar_ember`) only to its own CLI and checks the CLI version,
    /// so the request identifies as the installed Claude Code.
    public static func userAgent(version: String) -> String { "claude-cli/\(version) (external, cli)" }

    static let fallbackClaudeCodeVersion = "2.1.284"

    /// The native installer links `~/.local/bin/claude` to `…/versions/<x.y.z>`; anything else falls back.
    public static func claudeCodeVersion(launcher: String = NSHomeDirectory() + "/.local/bin/claude") -> String {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: launcher) else {
            return fallbackClaudeCodeVersion
        }
        let version = (target as NSString).lastPathComponent
        return version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? version : fallbackClaudeCodeVersion
    }

    public static func parse(status: Int, body: Data, plan: String?, now: Date = Date()) throws -> ProviderUsage {
        if status == 401 || status == 403 { throw UsageError.authExpired(loginHint) }
        guard status == 200 else { throw UsageError.failed("Claude: HTTP \(status)") }
        guard body.count <= maxBodyBytes,
              let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { throw UsageError.failed("Claude: bad response") }

        func window(_ key: String) throws -> UsageWindow? {
            guard let w = root[key] as? [String: Any] else { return nil }
            let raw = w["utilization"]
            if jsonIsNull(raw) { return nil }
            let used = try requireNumber(raw, "Claude: bad \(key) utilization")
            let resetsAt = (w["resets_at"] as? String).flatMap(parseISO8601)
            return UsageWindow(usedPercent: used, resetsAt: resetsAt)
        }

        var usage = ProviderUsage(plan: plan)
        usage.fiveHour = try window("five_hour")
        usage.weekly = try window("seven_day")
        usage.fableWeekly = try fableWindow(fromLimits: root["limits"]) ?? window("seven_day_overage_included")
        usage.resets = resetCredits(root["cedar_ember"], now: now)
        return usage
    }

    /// The Fable weekly limit from the live `limits` array. Live shape (2026-10-03):
    ///   [{"kind":"session","group":"session","percent":1,"resets_at":"…","scope":null,…},
    ///    {"kind":"weekly_all","group":"weekly","percent":77,"resets_at":"…","scope":null,…},
    ///    {"kind":"weekly_scoped","group":"weekly","percent":91,"severity":"critical","resets_at":"…",
    ///     "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]
    /// Returns nil when there is no such entry, so the caller falls back to `seven_day_overage_included`.
    static func fableWindow(fromLimits limits: Any?) throws -> UsageWindow? {
        guard let entries = limits as? [Any] else { return nil }
        for case let entry as [String: Any] in entries where entry["kind"] as? String == "weekly_scoped" {
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            guard (model?["display_name"] as? String)?.lowercased() == "fable" else { continue }
            let used = try requireNumber(entry["percent"], "Claude: bad Fable percent")
            return UsageWindow(usedPercent: used, resetsAt: (entry["resets_at"] as? String).flatMap(parseISO8601))
        }
        return nil
    }

    /// Weekly reset grants: available = live, non-paused; paused = live, paused.
    static func resetCredits(_ cedarEmber: Any?, now: Date) -> ResetCredits? {
        guard let ce = cedarEmber as? [String: Any], let grants = ce["grants"] as? [Any] else { return nil }
        let weeklyKeys: Set<String> = ["seven_day", "seven_day_overage_included"]
        var available = 0, paused = 0
        var soonest: Date?
        for item in grants {
            guard let g = item as? [String: Any] else { continue }
            let clears = (g["clears"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard clears.isEmpty || clears.contains(where: weeklyKeys.contains) else { continue }
            let left = Int(jsonNumber(g["resets_left"]) ?? 0)
            let endsAt = (g["ends_at"] as? String).flatMap(parseISO8601)
            guard left > 0, endsAt.map({ $0 > now }) ?? true else { continue }
            if jsonBool(g["paused"]) == true {
                paused += left
            } else {
                available += left
                if let e = endsAt, soonest.map({ e < $0 }) ?? true { soonest = e }
            }
        }
        return ResetCredits(available: available, paused: paused, soonestExpiry: soonest)
    }

    /// Refuses every redirect so the bearer token never leaves api.anthropic.com.
    final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func fetch(token: String, plan: String?, session: URLSession = .shared) async throws -> ProviderUsage {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: usageRequest(accessToken: token), delegate: NoRedirect())
        } catch is URLError {
            throw UsageError.failed("Claude: offline")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try parse(status: status, body: data, plan: plan)
    }
}
