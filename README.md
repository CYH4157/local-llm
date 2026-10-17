# 本地端 LLM + Discord Bot（vLLM 版）

在實驗室筆電（RTX 4070 Laptop 8GB）用 **vLLM** 跑本地模型，透過 Discord bot 提供快速問答、上網查詢，以及產生 **PowerPoint / Word / Excel** 草稿（研究計畫、投影片、課堂報告）。

> 實驗室成員用 **opencode** 連線寫程式、寫作，是另一個專案 `Documents\opencode`（vLLM :8000），不在這裡。

## 架構

```
Windows 筆電
├─ WSL2 (Ubuntu)
│   └─ llama-swap :8080（systemd 服務，開機自動啟動，只聽本機、需 API 金鑰）
│        │  依 request 的 model 名稱自動啟動 / 切換 vLLM，閒置 30 分鐘自動卸載釋放 GPU
│        ├─ vLLM: qwen3-8b    Qwen3-8B-AWQ（預設，寫作品質最好，上下文 6k）
│        ├─ vLLM: qwen3-4b    Qwen3-4B-Instruct-2507-FP8（快、上下文 12k）
│        └─ vLLM: qwen2.5-7b  Qwen2.5-7B-Instruct-AWQ（備用）
└─ Discord Bot（Python，Windows 端）→ http://127.0.0.1:8080/v1（OpenAI 相容 API）
     ├─ 聊天 / !web
     ├─ !ppt / !word / !excel → 模型輸出 JSON（vLLM 強制符合 schema）→ python-pptx / python-docx / openpyxl
     └─ !model <名稱>        → 切換模型（全體共用）
```

**為什麼要加 llama-swap？** vLLM 一個程序只能載一個模型，而且啟動就會先佔住顯存。
llama-swap 放在 vLLM 前面，負責「切換模型」和「閒置時卸載」。bot 切換模型只需要換 model 名稱。

---

## 安裝

### 1. 裝 WSL2（只需一次）
以**系統管理員**開 PowerShell：
```powershell
wsl --install -d Ubuntu
```
重開機後依提示設定 Ubuntu 使用者名稱與密碼。Windows 端要裝最新版 NVIDIA 驅動（**不要**在 Ubuntu 裡另外裝驅動）。

### 2. 跑部署腳本
```powershell
cd C:\Users\a9756\Documents\llm\local-llm
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```
腳本會：在 WSL 裝 vLLM + llama-swap 並註冊服務 → 預先下載預設模型 → 建 Windows 端 bot 環境 → 產生或補齊 `.env`。
中途會要你輸入 Ubuntu 密碼。第一次大約要下載 15GB（vLLM 約 8GB、模型約 6GB）。

| 參數 | 說明 |
|------|------|
| `-SkipWsl` | 只更新 bot，不動 WSL 端 |
| `-SkipWarmup` | 不預先下載模型（第一次提問時才下載） |
| `-DefaultModel qwen3-4b` | 換預設模型 |

### 3. 建立 Discord Bot、拿 Token
1. 到 https://discord.com/developers/applications → **New Application**
2. 左側 **Bot** → **Reset Token** 複製 token
3. 同一頁把 **MESSAGE CONTENT INTENT** 打開（一定要開，不然 bot 收不到訊息）
4. **OAuth2 → URL Generator**：Scopes 勾 `bot`；權限勾 `Send Messages`、`Read Message History`、`View Channels`、**`Attach Files`**（上傳產出的檔案需要）
5. 用產生的網址把 bot 邀進伺服器
6. 把 token 填進 `.env` 的 `DISCORD_BOT_TOKEN=`

### 4. 啟動
- 測試：雙擊 `start-bot.bat`
- 正式：以**系統管理員**執行 `install-autostart.ps1`，登入時會自動啟動 WSL 常駐和 bot，bot 掛掉也會自動重啟

> 筆電請插電，並把「接上電源時的睡眠」設為永不。

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
| `!model` / `!model <名稱>` | 查看 / 切換模型（全體共用，會記住） |
| `!status` | 看 GPU 上目前載入哪個模型 |
| `!reset` | 清空此頻道記憶 |
| `!help` | 說明 |

**參考資料**：產檔指令可以**附上 .txt / .md / .docx / .pdf**，或用 Discord 的「回覆」回覆某則訊息，模型會以那些內容為準。
範例：回覆一則會議記錄訊息，輸入 `!ppt 整理成組會報告`。

**範本**：把實驗室的 `ppt_template.pptx`、`word_template.docx` 放進 [templates/](templates/README.md) 就會自動套用。

**使用建議**
- 要附長篇 PDF 產報告時，先 `!model qwen3-4b`（上下文較長），並把 `.env` 的 `REF_MAX_CHARS` 調到約 8000
- 8B 模型產出的是**草稿**。參考文獻一律標為「[待補]」，模型被要求不可捏造文獻；數據和論述都請人工查證

---

## 設定（`.env`）

| 變數 | 說明 |
|------|------|
| `LLM_BASE_URL` | llama-swap 位址，預設 `http://127.0.0.1:8080/v1` |
| `LLM_API_KEY` | API 金鑰（deploy.ps1 自動產生並同步到 WSL） |
| `DEFAULT_MODEL` | 預設模型（`!model` 切換後會存在 `bot_state.json`，優先使用） |
| `SYSTEM_PROMPT` | bot 個性 |
| `MAX_HISTORY` / `HISTORY_MAX_CHARS` | 對話記憶則數和總字數上限 |
| `REF_MAX_CHARS` | 附件參考資料字數上限 |
| `TO_TRADITIONAL` | 自動簡轉繁（1/0） |
| `DOC_FONT_EA` / `DOC_FONT_LATIN` / `PPT_FONT` | 文件字型 |
| `ALLOWED_CHANNEL_ID` | 限定一般聊天的頻道 |
| `SEARCH_ENGINE` / `GOOGLE_API_KEY` / `GOOGLE_CSE_ID` | 聯網搜尋（沒設定時會自動改用 DuckDuckGo） |

## 新增 / 調整模型
編輯 `wsl/llama-swap.yaml` → 重跑 `deploy.ps1`（或在 WSL 裡複製到 `~/llm/llama-swap.yaml`，llama-swap 偵測到變更會自動重新載入）。
在 Discord 輸入 `!model` 就會看到新的模型。顯存調校方式寫在該檔開頭的註解。

## 檔案清單
| 檔案 | 用途 |
|------|------|
| `discord_bot.py` | Discord bot 本體（指令處理） |
| `llm_client.py` | 呼叫 OpenAI 相容 API、JSON 結構化輸出 |
| `office_gen.py` | JSON schema、提示詞、pptx/docx/xlsx 排版 |
| `wsl/llama-swap.yaml` | 模型清單與 vLLM 參數 |
| `wsl/setup-wsl.sh` | WSL 端安裝（vLLM、llama-swap、systemd） |
| `deploy.ps1` | 一鍵部署（Windows 端） |
| `install-autostart.ps1` | 開機自動啟動（WSL 常駐 + bot） |
| `run-bot.ps1` / `start-bot.bat` | 手動啟動 bot |
| `templates/` | 實驗室自訂範本（選用） |
| `outputs/` | 產出的檔案（不進 git） |

維運與疑難排解請看 [DEPLOY.md](DEPLOY.md)。
