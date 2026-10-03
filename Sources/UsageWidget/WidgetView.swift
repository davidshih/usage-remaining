import SwiftUI
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude: ProviderSnapshot?
    @Published var codex: ProviderSnapshot?
    @Published var lastUpdated: Date?
    @Published var compact: Bool {
        didSet { UserDefaults.standard.set(compact, forKey: "compactMode") }
    }
    private(set) var refreshing = false
    private var lastRefreshStart: Date?

    init() {
        compact = UserDefaults.standard.bool(forKey: "compactMode")
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastRefreshStart = Date()

        // Independent fetches: a Claude failure never cancels or hides Codex.
        let claudeTask = Task.detached { await UsageStore.fetchClaude() }
        let codexTask = Task.detached { await UsageStore.fetchCodex() }
        var pending = 2
        func finishOne() {
            pending -= 1
            if pending == 0 {
                lastUpdated = Date()
                refreshing = false
            }
        }
        Task {
            let result = await claudeTask.value
            claude = nextSnapshot(previous: claude, result: result)
            finishOne()
        }
        Task {
            let result = await codexTask.value
            codex = nextSnapshot(previous: codex, result: result)
            finishOne()
        }
    }

    /// Called every second: refresh early when a displayed window has passed its reset time.
    func refreshIfResetPassed(now: Date = Date()) {
        let windows = [claude?.usage, codex?.usage].compactMap { $0 }
            .flatMap { [$0.fiveHour, $0.weekly, $0.fableWeekly] }
        guard windows.contains(where: { currentWindow($0, now: now).resetPassed }) else { return }
        if let last = lastRefreshStart, now.timeIntervalSince(last) < 30 { return }
        refresh()
    }

    nonisolated static func fetchClaude() async -> Result<ProviderUsage, UsageError> {
        do {
            let json = try Claude.readKeychain()
            let token = try Claude.accessToken(fromKeychainJSON: json)
            let plan = Claude.subscriptionType(fromKeychainJSON: json)
            return .success(try await Claude.fetch(token: token, plan: plan))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.failed("Claude: unexpected error"))
        }
    }

    nonisolated static func fetchCodex() async -> Result<ProviderUsage, UsageError> {
        guard let path = Codex.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure(.failed("Codex CLI not found"))
        }
        do {
            return .success(try await Codex.fetch(executable: path))
        } catch let error as UsageError {
            return .failure(error)
        } catch {
            return .failure(.failed("Codex: unexpected error"))
        }
    }
}

// MARK: - View

/// Dark green on light backgrounds, a lighter green in dark mode where the dark one disappears.
private let creditGreenLight = Color(red: 0x27 / 255, green: 0x50 / 255, blue: 0x0A / 255)
private let creditGreenDark = Color(red: 0x97 / 255, green: 0xC4 / 255, blue: 0x59 / 255)

private func levelColor(_ percent: Double) -> Color {
    switch usageLevel(percent) {
    case .ok: return .green
    case .warn: return .orange
    case .critical: return .red
    }
}

private func percentText(_ percent: Double) -> String {
    "\(Int(min(100, max(0, percent)).rounded()))%"
}

struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

/// One dark-green dot per available reset credit, hollow dots for paused ones (max 5 drawn).
struct CreditDots: View {
    var resets: ResetCredits?
    var now: Date
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let creditGreen = colorScheme == .dark ? creditGreenDark : creditGreenLight
        if let r = resets, r.available + r.paused > 0 {
            let filled = min(r.available, 5)
            let hollow = min(r.paused, 5 - filled)
            HStack(spacing: 3) {
                ForEach(0..<filled, id: \.self) { _ in Circle().fill(creditGreen).frame(width: 6, height: 6) }
                ForEach(0..<hollow, id: \.self) { _ in Circle().strokeBorder(creditGreen, lineWidth: 1.2).frame(width: 6, height: 6) }
            }
            .help(tooltip(r))
        }
    }
    private func tooltip(_ r: ResetCredits) -> String {
        var s = "\(r.available) weekly reset\(r.available == 1 ? "" : "s")"
        if r.paused > 0 { s += " (+\(r.paused) paused)" }
        if let exp = r.soonestExpiry { s += " · next expires in " + formatCountdown(to: exp, now: now) }
        return s
    }
}

struct WidgetView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if store.compact { compactBody(now: context.date) } else { fullBody(now: context.date) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .fixedSize()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Full layout (table: name | 5h | Week)

    private func fullBody(now: Date) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("5h").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Week").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            providerRows("Claude", store.claude, now: now)
            GridRow { Color.clear.frame(height: 6).gridCellColumns(3) }
            providerRows("Codex", store.codex, now: now)
        }
    }

    @ViewBuilder
    private func providerRows(_ name: String, _ snapshot: ProviderSnapshot?, now: Date) -> some View {
        let stale = snapshot?.stale ?? false
        GridRow {
            HStack(spacing: 5) {
                Text(name).fontWeight(.semibold)
                CreditDots(resets: snapshot?.usage?.resets, now: now)
            }
            .padding(.top, 1)
            if let usage = snapshot?.usage {
                cell(usage.fiveHour, weekly: false, fable: nil, stale: stale, now: now)
                cell(usage.weekly, weekly: true, fable: usage.fableWeekly, stale: stale, now: now)
            } else {
                messageText(snapshot).gridCellColumns(2)
            }
        }
        .opacity(stale ? 0.5 : 1)
        if stale, let error = snapshot?.error {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Text("stale · " + error.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(2)
            }
        }
    }

    /// Bar (+ thin Fable bar under Week) and a single line "<percent> <countdown>".
    private func cell(_ raw: UsageWindow?, weekly: Bool, fable: UsageWindow?, stale: Bool, now: Date) -> some View {
        let current = currentWindow(raw, now: now)
        let percent = current.window?.usedPercent ?? 0
        let critical = current.window != nil && usageLevel(percent) == .critical
        return VStack(alignment: .leading, spacing: 3) {
            UsageBar(fraction: current.window == nil ? 0 : percent / 100,
                     color: stale ? .secondary : levelColor(percent))
            if let fable {
                let f = currentWindow(fable, now: now)
                let fp = f.window?.usedPercent ?? 0
                UsageBar(fraction: fp / 100, color: stale ? .secondary : levelColor(fp), height: 3)
                    .help("Fable " + percentText(fp) + (f.window?.resetsAt.map { " · " + formatWeeklyReset(to: $0, now: now) } ?? ""))
            }
            HStack(spacing: 4) {
                Text(current.window.map { percentText($0.usedPercent) } ?? "—")
                    .foregroundStyle(critical && !stale ? Color.red : Color.primary)
                Text(countdown(current, now: now)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .help(resetHelp(current, weekly: weekly, now: now))
        }
        .frame(width: 104, alignment: .leading)
    }

    private func countdown(_ current: (window: UsageWindow?, resetPassed: Bool), now: Date) -> String {
        if current.resetPassed { return "↻" }
        guard let at = current.window?.resetsAt else { return "—" }
        return formatCountdown(to: at, now: now)
    }

    private func resetHelp(_ current: (window: UsageWindow?, resetPassed: Bool), weekly: Bool, now: Date) -> String {
        if current.resetPassed { return "reset — updating…" }
        guard let at = current.window?.resetsAt else { return "resets in —" }
        return "resets in " + (weekly ? formatWeeklyReset(to: at, now: now) : formatCountdown(to: at, now: now))
    }

    @ViewBuilder
    private func messageText(_ snapshot: ProviderSnapshot?) -> some View {
        if let error = snapshot?.error {
            Text(error.message)
                .font(.system(size: 11.5))
                .foregroundStyle(error.isAuth ? Color.orange : Color.secondary)
                .lineLimit(nil)
                .frame(width: 218, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("loading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    // MARK: Compact layout (one aligned line per provider)

    private func compactBody(now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 3) {
            compactRow("Claude", store.claude, now: now)
            compactRow("Codex", store.codex, now: now)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
    }

    @ViewBuilder
    private func compactRow(_ name: String, _ snapshot: ProviderSnapshot?, now: Date) -> some View {
        let stale = snapshot?.stale ?? false
        GridRow {
            Text(name).fontWeight(.semibold).fixedSize()
            if let usage = snapshot?.usage {
                let five = currentWindow(usage.fiveHour, now: now)
                let week = currentWindow(usage.weekly, now: now)
                Text("5h").foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(five.window.map { percentText($0.usedPercent) } ?? "—")
                        .foregroundStyle(five.window.map { usageLevel($0.usedPercent) == .critical } == true && !stale ? Color.red : Color.primary)
                    Text(countdown(five, now: now).replacingOccurrences(of: " ", with: "")).foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.secondary)
                Text("W").foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(week.window.map { percentText($0.usedPercent) } ?? "—")
                    Text(leadingUnit(week, now: now)).foregroundStyle(.secondary)
                }
                CreditDots(resets: usage.resets, now: now)
            } else {
                messageText(snapshot).gridCellColumns(6)
            }
        }
        .lineLimit(1)
        .opacity(stale ? 0.5 : 1)
        .help(stale ? "stale · " + (snapshot?.error?.message ?? "") : "")
    }

    /// The leading unit of the countdown ("4d" of "4d 12h").
    private func leadingUnit(_ current: (window: UsageWindow?, resetPassed: Bool), now: Date) -> String {
        let s = countdown(current, now: now)
        return String(s.split(separator: " ").first ?? "")
    }
}

private extension UsageError {
    var isAuth: Bool {
        if case .authExpired = self { return true }
        return false
    }
}
