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

bot 跟 vLLM **跑在同一台**，金鑰自動讀那台的 `~/vllm-server/vllm.env`，`.env` 不用放金鑰。

| 主機 | vLLM 怎麼架 | bot 怎麼裝 | 常駐方式 |
|------|------|------|------|
| **Ubuntu 伺服器**（例如 H200） | `server/vllm/setup-vllm.sh` | `bash discord/client/deploy.sh` | systemd 服務 `discord-bot` |
| **Windows 筆電**（例如 RTX 4070 / 5070 Ti） | `server\wsl2\setup-host.cmd`（vLLM 在 WSL） | `discord\client\deploy.ps1` | 排程 `LocalLLM-DiscordBot` |

### 1. 建立 Discord Bot、拿 Token（兩種主機都一樣）
1. 到 https://discord.com/developers/applications → **New Application**
2. 左側 **Bot** → **Reset Token** 複製 token（token 等於 bot 本身，不要截圖或貼到任何地方）
3. 同一頁把 **MESSAGE CONTENT INTENT** 打開（一定要開，不然 bot 收不到訊息）
4. **OAuth2 → URL Generator**：Scopes 勾 `bot`；權限勾 `Send Messages`、`Read Message History`、`View Channels`、**`Attach Files`**（上傳產出的檔案需要）
5. 用產生的網址把 bot 邀進伺服器

> **token 是 Discord 的，不是 vLLM 的金鑰。** 兩把鑰匙不一樣，不要搞混：
>
> | | vLLM API 金鑰 | Discord bot token |
> |---|---|---|
> | 長相 | `sk-vllm-` 開頭 | 一長串英數字，中間有兩個 `.` |
> | 從哪裡來 | 裝 vLLM 時自動產生（`~/vllm-server/vllm.env`） | Developer Portal → Bot → Reset Token |
> | 用途 | opencode 和 bot 連進 vLLM | bot 登入 Discord |
> | 要填給 bot 嗎 | **不用**，bot 自動讀 | **要**，填 `--token` 或 `.env` 的 `DISCORD_BOT_TOKEN` |

> ⚠️ **兩台主機都要跑 bot 時，各建一個 Application（各一個 token）**，例如「LabGPT-H200」和「LabGPT-4070」。
> 同一個 token 同時在兩台跑，每則訊息都會被回兩次。兩個 bot 可以在同一個 Discord 伺服器，用 `ALLOWED_CHANNEL_ID` 分到不同頻道。

### 2A. Ubuntu 伺服器（H200）

先用 `server/vllm/setup-vllm.sh` 架好 vLLM，然後：

```bash
cd ~/local-llm && git pull
bash discord/client/deploy.sh --token <Discord_bot_token>
```

腳本會：確認同一台的 vLLM 正常 → 建立 Python 環境（`.venv`）→ 產生 `.env`（權限 600）→ 註冊並啟動 systemd 服務 `discord-bot`
（開機自動啟動、掛掉 10 秒後自動重啟）。看到「[已上線]」就完成，到 Discord 輸入 `!help` 試試看。

不想把 token 放在指令列（會留在 shell 歷史紀錄）：先執行 `bash discord/client/deploy.sh`，再 `nano discord/client/.env` 填
`DISCORD_BOT_TOKEN=`，最後 `sudo systemctl restart discord-bot`。

| 日常管理 | 指令 |
|------|------|
| 狀態 | `sudo systemctl status discord-bot` |
| 即時紀錄 | `journalctl -u discord-bot -f` |
| 改完 `.env` 後重啟 | `sudo systemctl restart discord-bot` |
| 更新程式 | `cd ~/local-llm && git pull && bash discord/client/deploy.sh` |
| 移除服務 | `bash discord/client/deploy.sh --uninstall`（`.env` 保留） |

### 2B. Windows 筆電（RTX 4070 / 5070 Ti）

先雙擊 `server\wsl2\setup-host.cmd` 架好 vLLM（見 [完整步驟.md 第 1 章](../../完整步驟.md#1-管理者架設筆電主機一次)），然後：

```powershell
cd <repo 根目錄>\discord\client
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```
腳本會：
1. 確認 vLLM 正常
2. 停用舊版自己架的 llama-swap（避免兩套 vLLM 搶顯卡）
3. 建立 bot 的 Python 環境
4. 自動填好 `.env` 的連線設定

接著把 token 填進 `.env` 的 `DISCORD_BOT_TOKEN=`，再啟動：
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

bot 會自動讀主機的金鑰（Ubuntu 直接讀 `~/vllm-server/vllm.env`、Windows 從 WSL 讀）、自動使用 vLLM 目前的模型，所以主機換金鑰或換模型後**都不用改 bot 的設定**。
怎麼取得 / 更換金鑰、怎麼換模型並套進 opencode，請看 [完整步驟.md 第 5 章](../../完整步驟.md#5-日常管理管理者)。

---

## 設定（`.env`）

| 變數 | 說明 |
|------|------|
| `LLM_BASE_URL` | vLLM 位址，預設 `http://127.0.0.1:8000/v1`（deploy.ps1 / deploy.sh 自動填） |
| `WSL_DISTRO` | 只有 Windows 用：vLLM 所在的 WSL 發行版（deploy.ps1 自動填） |
| `LLM_API_KEY` | 留空 = 自動讀主機的 vllm.env（建議）；bot 跟 vLLM 不在同一台時才填 |
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
| Discord 顯示「連不上 vLLM」 | 主機執行 `vllmctl status`（Windows：雙擊 `server\wsl2\vllmctl.cmd`；Ubuntu：`bash ~/local-llm/server/vllm/vllmctl.sh status`）；沒在跑就 `start` |
| bot 沒上線（Ubuntu） | `journalctl -u discord-bot -n 30`：`LoginFailure` = token 貼錯；`PrivilegedIntentsRequired` = 沒開 MESSAGE CONTENT INTENT |
| 每則訊息被回兩次 | 兩台主機用了同一個 token：各建一個 Application，或停掉其中一台 |
| 顯示「API 金鑰錯誤」 | `.env` 的 `LLM_API_KEY` 清空，重啟 bot |
| 顯示「內容太長」 | `!reset` 清記憶，或縮短附件；常發生就調小 `REF_MAX_CHARS` |
| 回應很慢 | 同學正在大量使用 opencode（共用同一張顯卡），稍等即可 |

## 檔案清單（都在 `discord/client/`）
| 檔案 | 用途 |
|------|------|
| `discord_bot.py` | Discord bot 本體（指令處理） |
| `llm_client.py` | 呼叫 vLLM、自動讀金鑰與模型、JSON 結構化輸出 |
| `office_gen.py` | JSON schema、提示詞、pptx/docx/xlsx 排版 |
| `deploy.ps1` | Windows 筆電一鍵部署 |
| `deploy.sh` | Ubuntu 伺服器一鍵部署（含 systemd 服務 `discord-bot`） |
| `install-autostart.ps1` | Windows：bot 開機自動啟動 |
| `run-bot.ps1` / `start-bot.bat` | 手動啟動 bot |
| `templates/` | 實驗室自訂範本（選用） |
| `outputs/` | 產出的檔案（不進 git） |
