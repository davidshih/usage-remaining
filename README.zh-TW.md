# UsageWidget

[English](README.md) · **繁體中文**

一個浮在 macOS 桌面上的小 widget，顯示 **Claude Code** 和 **Codex** 的用量還剩多少：5 小時視窗、
每週視窗、Claude 另外計算的 Fable 週上限，以及你手上的一次性「每週重置券」。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
  <img alt="UsageWidget 顯示 Claude 與 Codex 用量" src="docs/images/hero-light.png" width="420">
</picture>

## 功能

- **浮在最上層**：每個桌面空間（Space）都看得到；全螢幕 app 時自動讓開；拖到哪裡就記住哪裡。
- **5h 與 Week**：每家各一列，細 bar 加上一行「用量 % · 距離重置的時間」。滑鼠移到格子上會顯示確切的重置時間。
- **Fable 週上限**（Claude）：Claude 的 Week bar 底下多一條更細的 bar，滑鼠移上去看數字。
- **重置券**：名字旁邊一顆綠點代表一張可用的每週重置券；空心點是暫停（paused）中的券。滑鼠移上去看最近的到期時間。
- Bar 在 **70% 變橘**、**90% 變紅**。
- **精簡模式**：雙擊 widget，每家縮成對齊的一行。

  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/compact-dark.png">
    <img alt="精簡模式" src="docs/images/compact-light.png" width="380">
  </picture>

- 每 2 分鐘更新一次（視窗一重置也會馬上更新），倒數每秒跳動。
- 選單列圖示：顯示／隱藏、立即更新（⌘R）、精簡模式、登入時啟動、結束。

## 運作方式

![運作方式](docs/images/how-it-works.svg)

- **Codex**：執行你已安裝的 `codex app-server`，透過 JSON-RPC 呼叫 `account/rateLimits/read`。每次讀完都會把整個子行程樹清乾淨。
- **Claude Code**：從鑰匙圈讀取 Claude Code 存的 OAuth token（`Claude Code-credentials`，唯讀），再呼叫 `api.anthropic.com` 上的用量 API。

## 需求

- macOS 14 以上
- Swift 6 toolchain（Xcode 或 Command Line Tools）用來編譯
- 已登入的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)：才會有 Claude 那一列
- 已登入的 [Codex CLI](https://github.com/openai/codex)：才會有 Codex 那一列（會在 `/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin` 找）

只裝其中一個也可以，另一列會顯示錯誤訊息。

## 快速開始

```sh
git clone https://github.com/davidshih/usage-remaining.git
cd usage-remaining
scripts/build-app.sh --install
open ~/Applications/UsageWidget.app
```

第一次啟動會把 app 註冊成登入項目。要關掉的話，在選單取消勾選「Launch at Login」（macOS 可能會要你到「系統設定 → 一般 → 登入項目」核准）。

## 驗證

```sh
swift test   # 單元測試，離線即可執行
```

執行 `open ~/Applications/UsageWidget.app` 之後，螢幕右上角應該會出現 widget，選單列也會多一個儀表圖示。按「Refresh Now」（⌘R）會重新抓數字，可以跟 Claude Code 的 `/usage`、Codex 的 `/status` 對照。

## 各種狀態

| 登入過期 | 抓取失敗 |
|---|---|
| <img alt="登入過期" src="docs/images/state-auth.png" width="340"> | <img alt="資料過期" src="docs/images/state-stale.png" width="340"> |
| Claude 的 token 過期了：在終端機執行 `claude`，再輸入 `/login`。widget 下一次更新就會用新的 token。 | 保留上一次成功的數字，變淡顯示，下面寫失敗原因。 |

## 隱私與安全

- **全程唯讀。** 不寫入鑰匙圈、不更新你的 token（所以不會把 Claude Code 登出），也不會使用或領取任何重置券。
- **Token 只會送到 `api.anthropic.com`。** 拒絕所有重新導向，token 不會被轉送到別的地方。請求會帶 Claude Code 的 `User-Agent`（`claude-cli/<你安裝的版本> (external, cli)`），因為 Claude 只把重置券資訊回給自家的 CLI。
- **不記錄、不蒐集任何東西。** 沒有分析追蹤；widget 自己只發這一個用量請求，Codex 則透過它自己的 CLI 在本機查詢。

## 免責聲明

這是非官方工具，與 Anthropic 或 OpenAI 沒有任何關係，也未經其背書。它依賴未公開的介面（`/api/oauth/usage` 與 `codex app-server`），隨時可能變動或失效。Claude 那一列沒有綠點，通常代表你的帳號還沒有重置券；新訂閱不會馬上拿到。

## 開發

```sh
swift build
swift test
scripts/build-app.sh   # 只編出 dist/UsageWidget.app，不安裝
```

架構、資料格式和地雷：[docs/reference/development-zh-tw.md](docs/reference/development-zh-tw.md)。

## 移除

先在選單取消「Launch at Login」，從選單結束 app，然後：

```sh
rm -rf ~/Applications/UsageWidget.app
defaults delete com.davidshih.usagewidget
```

## 授權

[MIT](LICENSE)
