# 開發筆記

[English](development.md) · **繁體中文**

## 檔案結構

| 路徑 | 內容 |
|---|---|
| `Sources/UsageCore/Usage.swift` | 資料模型（`UsageWindow`、`ResetCredits`、`ProviderUsage`、`ProviderSnapshot`）、格式化函式、`currentWindow`、`nextSnapshot`、JSON 輔助函式 |
| `Sources/UsageCore/Codex.swift` | `codex app-server` 的 JSON-RPC client，以及子行程樹清理 |
| `Sources/UsageCore/Claude.swift` | 唯讀讀取鑰匙圈、用量請求、解析回應 |
| `Sources/UsageWidget/main.swift` | `NSPanel`、選單列圖示、登入項目、計時器 |
| `Sources/UsageWidget/WidgetView.swift` | `UsageStore`（抓資料、快照）與 SwiftUI 畫面 |
| `Tests/UsageCoreTests/` | `UsageCore` 的 Swift Testing 測試 |
| `scripts/build-app.sh` | Release 編譯 → `dist/UsageWidget.app`（ad-hoc 簽章）；`--install` 會複製到 `~/Applications` |

`UsageCore` 不依賴 AppKit，所有解析和子行程處理都在這裡，不用 UI 就能測。每個會碰到外部世界的函式都可以注入依賴（執行檔路徑、鑰匙圈工具路徑、`URLSession`）。

## 資料來源

### Codex

`codex app-server` 走 JSON-RPC，stdin / stdout 每行一個 JSON 物件：

```text
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-widget","version":"0.1"}}}
→ {"jsonrpc":"2.0","method":"initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}
← {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":76,"windowDurationMins":300,"resetsAt":…},
                                  "secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":…},
                                  "planType":"plus"},
                    "rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":…}]}}}
```

- 通知（`account/updated` 等）會混在同一條輸出裡，所以回應一律用 `id` 對。
- 視窗用 `windowDurationMins` 判斷（300 → 5h、10080 → 週），不看順序。
- 時間戳是 Unix 秒。

### Claude

`GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1`，帶 Claude Code 的 OAuth token（`Authorization: Bearer …`、`anthropic-beta: oauth-2025-04-20`）。用到的欄位：

| 欄位 | 用途 |
|---|---|
| `five_hour.utilization`、`.resets_at` | 5h |
| `seven_day.utilization`、`.resets_at` | Week |
| `limits[]` 裡 `kind: "weekly_scoped"` 且 `scope.model.display_name: "Fable"` 的那筆（`percent`、`resets_at`） | Fable 週上限 |
| `seven_day_overage_included` | Fable 週上限（舊格式的 fallback） |
| `cedar_ember.grants[]`（`resets_left`、`ends_at`、`paused`、`clears`） | 重置券 |

一張 grant 要算數，條件是 `resets_left > 0`、`ends_at` 還沒到，而且 `clears` 是空的或包含 `seven_day` / `seven_day_overage_included`。暫停中的 grant 畫成空心點。`resets_at` 帶微秒（`…T16:00:00.248374+00:00`），`parseISO8601` 可以處理 0 到 9 位小數。

## 行為

- 每家各自在獨立的 detached task 裡抓，Claude 失敗不會讓 Codex 的數字消失。
- 抓取失敗時，`nextSnapshot` 會保留上次成功的數字（標成 stale）；但如果是登入過期，就直接清掉。
- 重置時間已經過了的視窗，`currentWindow` 會顯示成 0%，store 也會馬上更新，在拿到新資料之前最多每 30 秒試一次。

## 地雷

- `/opt/homebrew/bin/codex` 是 Node 腳本。從 Finder 開的 app 不會繼承 shell 的 `PATH`，所以 `codexChildPATH` 會把 CLI 所在的目錄排第一，不然 `env node` 會失敗。
- Node 的啟動器會再開一個原生的 Codex 子行程，只殺直接的子行程，原生那支會留著繼續跑。`Codex.fetch` 會用 `pgrep -P` 走完整棵行程樹，全部收掉。
- 鑰匙圈透過 `/usr/bin/security` 讀取，因為那筆項目本來就信任它，所以不會跳出鑰匙圈授權視窗。若在這個沒簽章的 app 裡直接呼叫 `SecItemCopyMatching`，就會跳。
- `NSHostingView` 會吃掉 mouse-down，光設 `isMovableByWindowBackground` 拖不動 panel。`DraggableHostingView` 改成呼叫 `performDrag(with:)`，雙擊也在這裡處理。
- `ImageRenderer` 在淺色模式下渲染 material 時，文字深淺會出錯；顏色要以實際的 panel 為準。

## 測試

```sh
swift test
```

Codex CLI 用假腳本取代，Claude 的測試則把錄下來的 JSON 直接餵給解析器，所以整套離線就能跑，也不會碰你的鑰匙圈。

## 已知限制

- `User-Agent` 不是 Claude Code 的話，`cedar_ember` 會回 `ineligible_reason: "surface"` 而且沒有 grants，所以 Claude 那列不會出現重置券的點。
- 兩家的 API 都沒有公開文件，隨時可能改掉。
- 還沒驗證：有真實 grants 時 Claude 重置券點的顯示、重開機後登入項目的行為。
