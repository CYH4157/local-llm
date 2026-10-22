# Discord Bot（接實驗室的 vLLM）

Discord bot 提供快速問答、上網查詢，以及產生 **PowerPoint / Word / Excel** 草稿（研究計畫、投影片、課堂報告）。
模型**不在這個專案架設**，而是直接使用 repo 的 `opencode/` 資料夾在筆電 WSL 裡架的 vLLM。
opencode 和 Discord bot 共用同一個模型、同一張顯卡。

## 架構

```
Windows 筆電
├─ WSL2 Ubuntu
│   └─ vLLM :8000（opencode 專案架設；systemd 服務 vllm，需 API 金鑰）
│        ▲                         ▲
│        │                         └── 同學電腦的 opencode（http://筆電IP:8000/v1）
├─ opencode（筆電本機）──────────────┤
└─ Discord Bot（本專案）─────────────┘ http://127.0.0.1:8000/v1
     ├─ 聊天 / !web
     └─ !ppt / !word / !excel → 模型輸出 JSON（vLLM 強制符合 schema）→ python-pptx / python-docx / openpyxl
```

- **模型**：bot 每次自動問 vLLM 目前載入哪個模型，筆電用 `vllmctl` 換模型後 **bot 不用改任何設定**。
- **金鑰**：bot 自動從 WSL 的 `~/vllm-server/vllm.env` 讀取，筆電換金鑰後 **bot 也會自動重讀**。

---

## 安裝

### 1. 先架好 vLLM
雙擊 `server\wsl2\setup-host.cmd`（見 [完整步驟.md 第 1 章](../../完整步驟.md#1-管理者架設筆電主機一次)）。已經架好就跳過這一步。

### 2. 跑部署腳本
```powershell
cd <repo 根目錄>\discord\client
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```
腳本會：
1. 確認 vLLM 正常
2. 停用舊版自己架的 llama-swap（避免兩套 vLLM 搶顯卡）
3. 建立 bot 的 Python 環境
4. 自動填好 `.env` 的連線設定

### 3. 建立 Discord Bot、拿 Token
1. 到 https://discord.com/developers/applications → **New Application**
2. 左側 **Bot** → **Reset Token** 複製 token
3. 同一頁把 **MESSAGE CONTENT INTENT** 打開（一定要開，不然 bot 收不到訊息）
4. **OAuth2 → URL Generator**：Scopes 勾 `bot`；權限勾 `Send Messages`、`Read Message History`、`View Channels`、**`Attach Files`**（上傳產出的檔案需要）
5. 用產生的網址把 bot 邀進伺服器
6. 把 token 填進 `.env` 的 `DISCORD_BOT_TOKEN=`

### 4. 啟動
- 測試：雙擊 `discord\client\start-bot.bat`
- 正式：以**系統管理員**執行 `install-autostart.ps1`，登入時自動啟動 bot，掛掉也會自動重啟。WSL 常駐由 opencode 專案的 `vLLM-WSL-KeepAlive` 排程負責

---

## Bot 指令

| 指令 | 說明 |
|------|------|
| @提及 / 私訊 / 直接發言 | 一般聊天（離線） |
| `!web <問題>` | 上網搜尋後回答 |
| `!ppt <主題>` | 產生簡報 .pptx（16:9，含講者備註） |
| `!word 計畫 <題目>` | 國科會專題研究計畫草稿（背景、文獻、方法、甘特圖…） |
| `!word 報告 <主題>` | 課堂報告 .docx |
| `!word <需求>` | 一般文件 .docx |
| `!excel <需求>` | Excel 表格 .xlsx（可含公式，如預算表的小計和總計） |
| `!model` | 查看目前的模型（和 opencode 共用） |
| `!reset` | 清空此頻道記憶 |
| `!help` | 說明 |

**參考資料**：產檔指令可以**附上 .txt / .md / .docx / .pdf**，或用 Discord 的「回覆」回覆某則訊息，模型會以那些內容為準。
範例：回覆一則會議記錄訊息，輸入 `!ppt 整理成組會報告`。

**範本**：把實驗室的 `ppt_template.pptx`、`word_template.docx` 放進 [discord/client/templates/](../client/templates/README.md) 就會自動套用。

> 本地小模型產出的是**草稿**。參考文獻一律標為「[待補]」，模型被要求不可捏造文獻；數據和論述都請人工查證。

---

## 金鑰與換模型

bot 會自動從 WSL 讀金鑰、自動使用 vLLM 目前的模型，所以筆電換金鑰或換模型後**都不用改 bot 的設定**。
怎麼取得 / 更換金鑰、怎麼換模型並套進 opencode，請看 [完整步驟.md 第 5 章](../../完整步驟.md#5-日常管理管理者)。

---

## 設定（`.env`）

| 變數 | 說明 |
|------|------|
| `LLM_BASE_URL` | vLLM 位址，預設 `http://127.0.0.1:8000/v1`（deploy.ps1 自動填） |
| `WSL_DISTRO` | vLLM 所在的 WSL 發行版（deploy.ps1 自動填） |
| `LLM_API_KEY` | 留空 = 自動從 WSL 讀取（建議） |
| `SYSTEM_PROMPT` | bot 個性 |
| `MAX_HISTORY` / `HISTORY_MAX_CHARS` | 對話記憶則數和總字數上限 |
| `REF_MAX_CHARS` | 附件參考資料字數上限 |
| `TO_TRADITIONAL` | 自動簡轉繁（1/0） |
| `DOC_FONT_EA` / `DOC_FONT_LATIN` / `PPT_FONT` | 文件字型 |
| `ALLOWED_CHANNEL_ID` | 限定一般聊天的頻道 |
| `SEARCH_ENGINE` / `GOOGLE_API_KEY` / `GOOGLE_CSE_ID` | 聯網搜尋（沒設定時會自動改用 DuckDuckGo） |

## 疑難排解

| 症狀 | 處理 |
|------|------|
| Discord 顯示「連不上筆電上的 vLLM」 | `server\wsl2\vllmctl.cmd` 輸入 `status`；沒在跑就 `start` |
| 顯示「API 金鑰錯誤」 | `.env` 的 `LLM_API_KEY` 清空，重啟 bot |
| 顯示「內容太長」 | `!reset` 清記憶，或縮短附件；常發生就調小 `REF_MAX_CHARS` |
| 回應很慢 | 同學正在大量使用 opencode（共用同一張顯卡），稍等即可 |

## 檔案清單（都在 `discord/client/`）
| 檔案 | 用途 |
|------|------|
| `discord_bot.py` | Discord bot 本體（指令處理） |
| `llm_client.py` | 呼叫 vLLM、自動讀金鑰與模型、JSON 結構化輸出 |
| `office_gen.py` | JSON schema、提示詞、pptx/docx/xlsx 排版 |
| `deploy.ps1` | 一鍵部署 |
| `install-autostart.ps1` | bot 開機自動啟動 |
| `run-bot.ps1` / `start-bot.bat` | 手動啟動 bot |
| `templates/` | 實驗室自訂範本（選用） |
| `outputs/` | 產出的檔案（不進 git） |
