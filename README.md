# 實驗室 Discord Bot（接 vLLM）

Discord bot 提供快速問答、上網查詢，以及產生 **PowerPoint / Word / Excel** 草稿（研究計畫、投影片、課堂報告）。
模型**不在這個專案架設**，而是直接使用 opencode 專案（`Documents\opencode`）在筆電 WSL 裡架的 vLLM。
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
照 opencode 專案的 README 雙擊 `host\setup-host.cmd`。已經架好就跳過這一步。

### 2. 跑部署腳本
```powershell
cd C:\Users\a9756\Documents\llm\local-llm
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
- 測試：雙擊 `start-bot.bat`
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

**範本**：把實驗室的 `ppt_template.pptx`、`word_template.docx` 放進 [templates/](templates/README.md) 就會自動套用。

> 本地小模型產出的是**草稿**。參考文獻一律標為「[待補]」，模型被要求不可捏造文獻；數據和論述都請人工查證。

---

## API 金鑰怎麼取得

vLLM 的金鑰只有**一組**，存在筆電 WSL 的 `~/vllm-server/vllm.env`（`SERVE_API_KEY`）。opencode 和 Discord bot 都用這組。

| 我要… | 做法 |
|------|------|
| **看目前的金鑰**（要給同學時） | 在 opencode 資料夾雙擊 `host\vllmctl.cmd`，輸入 `info`，會印出網址和金鑰 |
| **換一組新金鑰**（有人離開、金鑰外流） | `vllmctl.cmd` 輸入 `new-key`，舊金鑰立刻失效 |
| 指定自己取的金鑰 | `vllmctl.cmd` 輸入 `new-key sk-lab-自己取的名字` |
| 換金鑰後：**Discord bot** | **不用動**。bot 遇到「金鑰錯誤」會自動從 WSL 重讀 |
| 換金鑰後：**筆電的 opencode** | 執行 `client\install-client.cmd -Url http://127.0.0.1:8000/v1 -SkipInstall`（本機會自動讀金鑰，不用貼） |
| 換金鑰後：**同學的 opencode** | 把新金鑰私下傳給同學，同學雙擊 `client\install-client.cmd`，貼上網址和新金鑰 |

**Hugging Face token**（`hf_` 開頭）是另一種東西：只有下載**需要授權的模型**（Llama、Gemma 等）才需要，Qwen 系列不用。
1. 到該模型的 Hugging Face 頁面按同意授權條款
2. 到 [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) 建立 **Read** 權限的 token
3. `vllmctl.cmd` 輸入 `set HF_TOKEN hf_xxxxxxxx`

> `.env` 的 `LLM_API_KEY` 請**留空**，讓 bot 自動讀取。只有 bot 不在筆電上執行（讀不到 WSL）時才需要填。

---

## vLLM 換新模型，怎麼套進 opencode

vLLM 一次只載入**一個**模型，換模型就是「下載新的 → 換掉舊的」。opencode、Discord bot 都會改用新模型。

### 步驟 1：在筆電換模型
在 opencode 資料夾雙擊 `host\vllmctl.cmd`，二選一：

**用內建組合**（最簡單，參數都調好了）：
```
presets              ← 列出可用組合
preset quality       ← 換成 Qwen3-8B
preset laptop        ← 換回預設的 Qwen3-4B（實測建議）
```

**用任意 Hugging Face 模型**：
```
model Qwen/Qwen3-8B-AWQ qwen3-8b 32768 hermes
```

| 欄位 | 說明 |
|------|------|
| `Qwen/Qwen3-8B-AWQ` | Hugging Face 上的模型 ID（到 huggingface.co 搜尋，複製頁面標題那串） |
| `qwen3-8b` | 在 opencode 裡顯示的名字（自己取，英數字） |
| `32768` | 上下文長度。opencode 至少要 16384，建議 32768；顯存不夠就調小 |
| `hermes` | tool calling 解析器。Qwen2.5 / Qwen3 用 `hermes`，Qwen3-Coder 用 `qwen3_coder` |

`vllmctl` 會**先下載完才切換**，所以下載期間大家照常使用，切換時服務中斷約 1 分鐘。
選模型時，**模型一定要支援 tool calling**（opencode 讀寫檔案要用），而且權重加上下文要放得進顯卡，詳見 opencode 使用教學第 7 章。

### 步驟 2：確認新模型正常
`vllmctl.cmd` 輸入 `bench`，大約 1 分鐘，會檢查速度、長文件、工具呼叫。

### 步驟 3：更新每一台的 opencode 設定
opencode 的設定檔（`%USERPROFILE%\.config\opencode\opencode.json`）記著模型名稱和上下文長度，換模型後要更新：

| 電腦 | 做法 |
|------|------|
| 筆電本機 | `client\install-client.cmd -Url http://127.0.0.1:8000/v1 -SkipInstall` |
| 同學（Windows） | 再雙擊一次 `client\install-client.cmd`，貼上同樣的網址和金鑰 |
| 同學（Ubuntu） | 重跑 `bash client/install-client.sh --url … --key … --name laptop` |

腳本會自動抓 vLLM 目前的模型和上下文，寫進 opencode 設定，原本指向舊模型的預設值也會自動改成新模型。
完成後開啟 opencode，輸入 `/models` 確認看到新模型。

### 步驟 4：Discord bot
**不用做任何事**。在 Discord 輸入 `!model` 可以確認 bot 已經在用新模型。

> 如果新模型的上下文變小（例如換成 16k 的 `small` 組合），建議把 `.env` 的 `REF_MAX_CHARS` 調到 5000，再重啟 bot。

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
| Discord 顯示「連不上筆電上的 vLLM」 | `vllmctl.cmd` 輸入 `status`；沒在跑就 `start` |
| 顯示「API 金鑰錯誤」 | `.env` 的 `LLM_API_KEY` 清空，重啟 bot |
| 顯示「內容太長」 | `!reset` 清記憶，或縮短附件；常發生就調小 `REF_MAX_CHARS` |
| 回應很慢 | 同學正在大量使用 opencode（共用同一張顯卡），稍等即可 |

## 檔案清單
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
