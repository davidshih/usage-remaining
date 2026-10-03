# Development notes

**English** · [繁體中文](development-zh-tw.md)

## Layout

| Path | What it is |
|---|---|
| `Sources/UsageCore/Usage.swift` | Models (`UsageWindow`, `ResetCredits`, `ProviderUsage`, `ProviderSnapshot`), formatters, `currentWindow`, `nextSnapshot`, JSON helpers |
| `Sources/UsageCore/Codex.swift` | `codex app-server` JSON-RPC client and process-tree cleanup |
| `Sources/UsageCore/Claude.swift` | Read-only Keychain read, the usage request, response parsing |
| `Sources/UsageWidget/main.swift` | `NSPanel`, menu bar item, login item, timers |
| `Sources/UsageWidget/WidgetView.swift` | `UsageStore` (fetching, snapshots) and the SwiftUI view |
| `Tests/UsageCoreTests/` | Swift Testing tests for `UsageCore` |
| `scripts/build-app.sh` | Release build → `dist/UsageWidget.app`, ad-hoc signed; `--install` copies it to `~/Applications` |

`UsageCore` has no AppKit dependency and is where all parsing and process handling lives, so it
can be tested without a UI. Every function that touches the outside world takes an injectable
dependency (executable path, Keychain tool path, `URLSession`).

## Data sources

### Codex

`codex app-server` speaks JSON-RPC, one JSON object per line on stdin/stdout:

```text
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-widget","version":"0.1"}}}
→ {"jsonrpc":"2.0","method":"initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}
← {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":76,"windowDurationMins":300,"resetsAt":…},
                                  "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":…},
                                  "planType":"plus"},
                    "rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":…}]}}}
```

- Notifications (`account/updated`, …) arrive on the same stream, so responses are matched by `id`.
- Windows are mapped by `windowDurationMins` (300 → 5h, 10080 → week), not by position.
- Timestamps are Unix seconds.

### Claude

`GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1` with the Claude Code
OAuth token (`Authorization: Bearer …`, `anthropic-beta: oauth-2025-04-20`) and Claude Code's
`User-Agent`, `claude-cli/<version> (external, cli)`. The version is read from the native
installer's `~/.local/bin/claude` → `…/versions/<x.y.z>` link (fallback `2.1.284`). With any other
User-Agent, `cedar_ember` answers `ineligible_reason: "surface"` with no grants, and it also checks
the CLI version (`cli_version`), so the version is not hard-coded. Fields used:

| Field | Used for |
|---|---|
| `five_hour.utilization`, `.resets_at` | 5h |
| `seven_day.utilization`, `.resets_at` | Week |
| `limits[]` entry with `kind: "weekly_scoped"` and `scope.model.display_name: "Fable"` (`percent`, `resets_at`) | Fable weekly |
| `seven_day_overage_included` | Fable weekly, fallback for older responses |
| `cedar_ember.grants[]` (`resets_left`, `ends_at`, `paused`, `clears`) | Reset credits |

A grant counts when `resets_left > 0`, `ends_at` is in the future, and `clears` is empty or contains
`seven_day` / `seven_day_overage_included`. Paused grants become hollow dots. `resets_at` values
carry microseconds (`…T16:00:00.248374+00:00`); `parseISO8601` handles 0–9 fractional digits.

## Behavior

- Each provider is fetched in its own detached task, so a Claude failure never hides Codex numbers.
- `nextSnapshot` keeps the last good numbers on a failure (marked stale) but drops them when the
  login expired.
- `currentWindow` shows a window whose reset time has passed as 0 %; the store then refreshes at
  most once every 30 s until fresh data arrives.

## Gotchas

- `/opt/homebrew/bin/codex` is a Node script. Apps launched from Finder don't inherit your shell
  `PATH`, so `codexChildPATH` puts the CLI's own directory first or `env node` fails.
- The Node launcher spawns the native Codex binary as a child; killing only the direct child
  leaves it running. `Codex.fetch` walks the process tree with `pgrep -P` and kills all of it.
- The Keychain is read through `/usr/bin/security`, which the item already trusts, so there is no
  Keychain prompt. Calling `SecItemCopyMatching` from this unsigned app would prompt.
- `NSHostingView` swallows mouse-down, so `isMovableByWindowBackground` alone doesn't drag the
  panel. `DraggableHostingView` calls `performDrag(with:)` and handles the double-click.
- `ImageRenderer` renders light-mode materials with the wrong text contrast; check colors on the
  real panel.

## Testing

```sh
swift test
```

The Codex CLI is replaced by a fake script and the Claude tests feed recorded JSON to the
parser, so the suite runs offline and never touches your Keychain.

## Known limitations

- New subscriptions get `ineligible_reason: "tenure"` (no grants) for their first weeks.
- Both providers' endpoints are undocumented and can change without notice.
- Not verified yet: Claude reset dots with real grants, and the login item after a reboot.
