import Foundation
import Darwin

public enum Codex {
    public static let candidatePaths: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/codex"),
    ]

    static let maxOutputBytes = 1 << 20

    static let requestLines = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-widget","version":"0.1"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
    ]

    // MARK: Parsing

    /// The JSON object on `line` when it is the response with id 2, else nil.
    static func responseObject(_ line: Substring) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = jsonNumber(obj["id"]), id == 2
        else { return nil }
        return obj
    }

    public static func parse(stdout: String) throws -> ProviderUsage {
        guard let response = stdout.split(whereSeparator: \.isNewline).lazy.compactMap(responseObject).first else {
            throw UsageError.failed("Codex: no rate-limit response")
        }
        if let err = response["error"], !(err is NSNull) {
            let message = ((err as? [String: Any])?["message"] as? String) ?? "unknown error"
            throw UsageError.failed("Codex: " + String(message.prefix(120)))
        }
        guard let result = response["result"] as? [String: Any] else {
            throw UsageError.failed("Codex: bad response")
        }

        var usage = ProviderUsage()
        let rateLimits = result["rateLimits"] as? [String: Any]
        usage.plan = rateLimits?["planType"] as? String

        for (position, key) in ["primary", "secondary"].enumerated() {
            guard let raw = rateLimits?[key], !jsonIsNull(raw) else { continue }
            guard let w = raw as? [String: Any] else { throw UsageError.failed("Codex: bad \(key) window") }
            let used = try requireNumber(w["usedPercent"], "Codex: bad \(key) usedPercent")
            let resetsAt = jsonNumber(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
            let window = UsageWindow(usedPercent: used, resetsAt: resetsAt)
            let isFiveHour: Bool
            switch jsonNumber(w["windowDurationMins"]) {
            case 300?: isFiveHour = true
            case 10080?: isFiveHour = false
            default: isFiveHour = position == 0
            }
            if isFiveHour {
                if usage.fiveHour == nil { usage.fiveHour = window }
            } else if usage.weekly == nil {
                usage.weekly = window
            }
        }

        if let credits = result["rateLimitResetCredits"] as? [String: Any] {
            let available = jsonNumber(credits["availableCount"]).map { Int($0) } ?? 0
            let list = (credits["credits"] as? [Any]) ?? []
            let soonest = list.compactMap { item -> Date? in
                guard let c = item as? [String: Any], (c["status"] as? String) == "available",
                      let exp = jsonNumber(c["expiresAt"]) else { return nil }
                return Date(timeIntervalSince1970: exp)
            }.min()
            usage.resets = ResetCredits(available: available, paused: 0, soonestExpiry: soonest)
        }
        return usage
    }

    // MARK: Fetching

    public static func fetch(executable: String, timeout: TimeInterval = 20) async throws -> ProviderUsage {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw UsageError.failed("Codex CLI not found")
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProviderUsage, Error>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(with: Result { try runAppServer(executable: executable, timeout: timeout) })
            }
        }
    }

    private final class ReadState: @unchecked Sendable {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var buffer = Data()
        var scanned = 0
        var finished = false
        var foundResponse = false
        var tooLarge = false

        /// Marks the read as finished (once) and wakes the waiter.
        func finish() {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first { done.signal() }
        }

        func append(_ chunk: Data) {
            lock.lock()
            buffer.append(chunk)
            var stop = false
            if buffer.count > Codex.maxOutputBytes {
                tooLarge = true
                stop = true
            } else {
                while let nl = buffer[scanned...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[scanned..<nl], as: UTF8.self)
                    scanned = nl + 1
                    if Codex.responseObject(Substring(line)) != nil {
                        foundResponse = true
                        stop = true
                        break
                    }
                }
            }
            lock.unlock()
            if stop { finish() }
        }
    }

    private static func runAppServer(executable: String, timeout: TimeInterval) throws -> ProviderUsage {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = codexChildPATH(codexPath: executable, inheritedPATH: env["PATH"])
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let state = ReadState()
        let exited = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.finish()
            } else {
                state.append(chunk)
            }
        }
        process.terminationHandler = { _ in
            exited.signal()
            // Give the reader a moment to drain what the process wrote before it exited.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { state.finish() }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            throw UsageError.failed("Codex: could not start (\(error.localizedDescription))")
        }

        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let request = Data((requestLines.joined(separator: "\n") + "\n").utf8)
        try? writer.write(contentsOf: request)

        let timedOut = state.done.wait(timeout: .now() + timeout) == .timedOut

        terminateTree(process)
        _ = exited.wait(timeout: .now() + 2)
        stdout.fileHandleForReading.readabilityHandler = nil
        try? writer.close()

        state.lock.lock()
        let output = state.buffer
        let found = state.foundResponse
        let tooLarge = state.tooLarge
        state.lock.unlock()

        if tooLarge { throw UsageError.failed("Codex: output too large") }
        if timedOut && !found { throw UsageError.failed("Codex: timed out") }
        return try parse(stdout: String(decoding: output, as: UTF8.self))
    }
}

// MARK: - Process tree control

/// Child pids of `pid`, via /usr/bin/pgrep -P.
func childPIDs(of pid: pid_t) -> [pid_t] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", String(pid)]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

/// All descendants of `pid`, collected recursively before anything is killed.
func descendantPIDs(of pid: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var queue = [pid]
    while let next = queue.popLast() {
        for child in childPIDs(of: next) where !result.contains(child) {
            result.append(child)
            queue.append(child)
        }
    }
    return result
}

/// SIGTERM the process and all its descendants, wait up to 1 s, then SIGKILL survivors.
func terminateTree(_ process: Process) {
    let pid = process.processIdentifier
    // Once the child is reaped its pid may be reused, so only walk a live child.
    guard pid > 0, process.isRunning else { return }
    let pids = descendantPIDs(of: pid) + [pid]
    for p in pids { kill(p, SIGTERM) }
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if pids.allSatisfy({ kill($0, 0) != 0 }) && !process.isRunning { return }
        usleep(50_000)
    }
    for p in pids where kill(p, 0) == 0 { kill(p, SIGKILL) }
}
