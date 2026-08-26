# 本地端 LLM + Discord Bot

在自己的機器上跑 LLM，透過 Discord 問答，支援 Google 聯網搜尋。
定位：**省 token 處理日常簡單問題**（不追求完全取代 Claude）。

## 架構

```
Ollama（模型引擎，開機自動啟動）
  └─ Qwen2.5 模型
       └─ Discord Bot（Python）
            ├─ 一般聊天         → 離線，0 網路流量
            ├─ !web <問題>      → Google 搜尋後回答（聯網）
            ├─ !reset / !model  → 清記憶 / 看模型
            └─ [規劃中] !ppt、!img
```

## 目前定位（機器分工）

| 機器 | 角色 | GPU |
|------|------|-----|
| **這台筆電（RTX 5070 Ti Laptop 12GB）** | 開發 / 測試 | 12GB |
| 電腦1（RTX 4070 12GB） | 未來正式部署 | 12GB |
| 電腦2 / 3（RTX 4060 Ti 8 或 16GB？待確認） | 未來擴充 | ? |

---

## 安裝步驟

### 1. 跑部署腳本（裝 Ollama + 下載模型 + 建 bot 環境）
```powershell
cd C:\Users\a9756\Documents\llm\local-llm
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# 想省流量用小模型：加  -Model "qwen2.5:7b"
```
> 一次性下載約 10GB（程式 + 模型 + 套件）。之後純聊天不耗流量。

### 2. 建立 Discord Bot、拿 Token（你自己操作）
1. 到 https://discord.com/developers/applications → **New Application**
2. 左側 **Bot** → **Reset Token** 複製 token
3. 同頁把 **MESSAGE CONTENT INTENT** 打開（一定要，不然 bot 收不到訊息）
4. 左側 **OAuth2 → URL Generator**：Scopes 勾 `bot`，Bot Permissions 勾
   `Send Messages`、`Read Message History`、`Read Messages/View Channels`
5. 用產生的網址把 bot 邀進你的伺服器

### 3. 填設定檔
記事本開啟 `.env`，至少填：
```
DISCORD_BOT_TOKEN=你的token
```

### 4.（選）設定 Google 聯網搜尋
`!web` 預設用 Google，需要兩個免費金鑰（免費 100 次/天）：
- **API Key**：https://console.cloud.google.com/ → 啟用 *Custom Search API* → 建立 API 金鑰
- **CSE ID**：https://programmablesearchengine.google.com/ → 建立搜尋引擎（設定「搜尋整個網路」）→ 複製「搜尋引擎 ID」

填進 `.env`：
```
GOOGLE_API_KEY=...
GOOGLE_CSE_ID=...
```
> 沒填也沒關係：`!web` 會自動改用 DuckDuckGo（免申請）。

### 5. 啟動 bot
**最簡單：雙擊 `start-bot.bat`** → 跳出視窗、bot 上線；視窗開著=在線，關掉=下線。
（等同執行 `run-bot.ps1`。）到 Discord **@提及 bot** 或私訊它試試。

> 測試筆電就用這種手動方式即可，關機停掉屬正常，下次雙擊再開。

### 6.（選，正式部署才需要）開機自動啟動
```powershell
# 需以「系統管理員」開啟 PowerShell 執行
powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1
```
之後 bot 會開機自動啟動、掛掉自動重試 → 不中斷。（測試筆電不需要。）

---

## Bot 指令
| 指令 | 說明 |
|------|------|
| @提及 / 私訊 / 直接發言 | 一般聊天（離線） |
| `!web <問題>` | Google 搜尋後回答 |
| `!reset` | 清空此頻道對話記憶 |
| `!model` | 顯示目前模型 |

`.env` 可調：`MODEL`、`SYSTEM_PROMPT`（bot 個性）、`MAX_HISTORY`（記憶長度）、
`ALLOWED_CHANNEL_ID`（限定頻道）、`SEARCH_ENGINE`。

---

## 檔案清單
| 檔案 | 用途 |
|------|------|
| `deploy.ps1` | 安裝 Ollama + 模型 + bot 環境 |
| `discord_bot.py` | Discord bot 本體 |
| `requirements.txt` | Python 套件 |
| `.env.example` / `.env` | 設定範本 / 實際設定 |
| `run-bot.ps1` | 前景啟動 bot（除錯用） |
| `install-autostart.ps1` | 註冊開機自動啟動 |
| `docker-compose.yml` | Docker 版留底（含 Open WebUI，非必要） |

---

## 規劃中（等聊天 bot 穩了再加）

- **`!ppt <主題>`**：模型寫大綱 → python-pptx 產生 .pptx → 上傳 Discord（低成本，跟聊天共用模型）
- **`!img <描述>`**：另裝 Stable Diffusion（ComfyUI/WebUI）+ SDXL 模型，bot 呼叫產圖（較重，品質不到雲端頂級）

---

## 正式部署容量規劃（10 人同時使用）

- **需求判斷**：10 人有帳號、通常錯開 → 單卡夠；10 人同一秒都送 → 需換引擎/模型或分流
- **單張 12GB 顯卡**：14B 跑 10 人會排隊；**7B** 較可行
- **引擎**：Ollama 好裝、適合開發；正式扛併發建議換 **vLLM**（continuous batching）
- **分階段**：
  | 階段 | 引擎 | 模型 | 機器 |
  |------|------|------|------|
  | 開發測試（現在） | Ollama | 14B | 筆電 |
  | 正式上線 | vLLM | 7B(4-bit) | 電腦1 |
  | 人變多/容錯 | vLLM×N + LiteLLM 分流 | 7B | 電腦1/2/3 |
- **多機分流**用 LiteLLM / nginx 輪詢即可，比 k3s 簡單。k3s 之後真要叢集再導入。

## 網路流量
- 安裝：一次性約 10GB
- 日常聊天：本地推論 **0 流量**
- 例外：`!web` 聯網搜尋，每次少量流量
