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

模型來源有兩種：**(A) 本地 vLLM**——bot 跟 vLLM **跑在同一台**，金鑰自動讀那台的 `~/vllm-server/vllm.env`，`.env` 不用放金鑰（下面 2A / 2B）；**(B) 遠端 gateway**——接外部 **OpenAI 相容**服務（例如國網 NCHC genai），不用自架 vLLM（下面 2C）。

| 主機 | vLLM 怎麼架 | bot 怎麼裝 | 常駐方式 |
|------|------|------|------|
| **Ubuntu 伺服器**（例如 H200） | `server/vllm/setup-vllm.sh` | `bash discord/client/deploy.sh` | systemd 服務 `discord-bot` |
| **Windows 筆電**（例如 RTX 4070 / 5070 Ti） | `server\wsl2\setup-host.cmd`（vLLM 在 WSL） | `discord\client\deploy.ps1` | 排程 `LocalLLM-DiscordBot` |

### 1. 建立 Discord Bot、拿 Token（兩種主機都一樣）
1. 到 https://discord.com/developers/applications → **New Application**
2. 左側 **Bot** → **Reset Token** 複製 token（token 等於 bot 本身，不要截圖或貼到任何地方）
3. 同一頁把 **MESSAGE CONTENT INTENT** 打開（一定要開，不然 bot 收不到訊息）
4. **OAuth2 → URL Generator**：Scopes 勾 `bot`；權限勾 `Send Messages`、`Read Message History`、`View Channels`、**`Attach Files`**（上傳產出的檔案需要）
5. **把 bot 加入伺服器**：複製最下面產生的網址 → 貼到瀏覽器打開 → 選要加入的伺服器（必須是**含你要用的頻道**那個）→ **Authorize**。授權後 bot 就會出現在該伺服器。

> ⚠️ **bot 程式在跑 ≠ 已加入伺服器。** 一定要走這一步邀請，否則 bot 不會出現在任何地方。加入後，在 `ALLOWED_CHANNEL_ID` 設的頻道直接打字就會回，其他頻道要 `@bot` 或私訊；先打 `!help` 或 `!model` 測試。兩支不同的 bot（各自的 token）要各邀一次。

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

其他選項（兩種模式都適用）：`--channel <頻道ID>` 只在該頻道自動回一般聊天、`--model <名稱>` 指定模型；`bash discord/client/deploy.sh --help` 看完整用法。

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

### 2C. 接遠端 gateway（不自架 vLLM）

bot 不一定要配本機 vLLM，也能接任何 **OpenAI 相容**的服務（例如國網 NCHC genai）。用 `deploy.sh` 的 `--remote` 指定網址、`--api-key` 指定金鑰，**不需要 `server/vllm` 那一套**：

```bash
cd ~/local-llm && git pull
bash discord/client/deploy.sh \
  --remote https://inner-medusa.genai.nchc.org.tw/v1 \
  --api-key <API_KEY> \
  --channel <頻道ID> \
  --token <Discord_bot_token>
```

- `--remote <URL>`：OpenAI 相容服務的 base URL（結尾 `/v1`）。
- `--api-key <KEY>`：該服務的金鑰。不想留在 shell 歷史紀錄就省略，裝完 `nano discord/client/.env` 填 `LLM_API_KEY`，再 `sudo systemctl restart discord-bot`。
- `--model <名稱>`：gateway 掛多個模型時指定要用哪個（**強烈建議指定**；不指定＝清單第一個，可能抓到語音/OCR 等非聊天模型）。怎麼查見下方。
- `--channel <頻道ID>`：只在這個頻道自動回一般聊天（見下方 `ALLOWED_CHANNEL_ID`）。

systemd 服務與日常管理指令跟 2A 相同（`systemctl` / `journalctl`）。不加 `--remote` 就是本地 vLLM（預設）。

#### 查 gateway 有哪些模型

列出所有模型名稱（一行一個、排序）：

```bash
curl -s https://inner-medusa.genai.nchc.org.tw/v1/models -H "Authorization: Bearer <KEY>" | jq -r '.data[].id' | sort
```

沒有 `jq` 就用純內建工具（不需要 python）：

```bash
curl -s https://inner-medusa.genai.nchc.org.tw/v1/models -H "Authorization: Bearer <KEY>" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | sort
```

清單會混很多**非聊天**模型，`--model` / `LLM_MODEL` 請挑**對話（chat / instruct）**的，避開：語音辨識（`Whisper-*`、`*-ASR-*`、`faster-whisper-*`）、語音合成（`cosyvoice`）、OCR（`*-ocr-*`）、向量/檢索（`bge-*`、`embedding*`、`*-reranker-*`、`jina-embeddings-*`）、內容審核（`*-safeguard-*`、`*-Guardian-*`）。NCHC 的繁中可用例：`Llama3-TAIDE-LX-70B-Chat`、`Gemma-3-TAIDE-12b-Chat`、`Llama-3.3-70B-Instruct`、`GLM-5.3`、`Kimi-K3-max`。

---

## Bot 指令

| 指令 | 說明 |
|------|------|
| @提及 / 私訊 / 直接發言 | 聊天；模型會自己決定要不要用工具（見下方「工具」） |
| `!web <問題>` | 強制先上網搜尋再回答 |
| `!tools` | 列出目前可用的工具與 MCP server 狀態 |
| `!skills` / `!skill <名稱>` | 列出技能 / 看某個技能內容 |
| `!skill del <名稱>` | 刪除技能（限管理員） |
| `!ppt <主題>` | 產生簡報 .pptx（16:9，含講者備註） |
| `!word 計畫 <題目>` | 國科會專題研究計畫草稿（背景、文獻、方法、甘特圖…） |
| `!word 報告 <主題>` | 課堂報告 .docx |
| `!word <需求>` | 一般文件 .docx |
| `!excel <需求>` | Excel 表格 .xlsx（可含公式，如預算表的小計和總計） |
| `!models` | 列出模型服務上可用的模型 |
| `!model [名稱\|auto]` | 不加參數＝看目前；加名稱＝切換模型（本次執行有效，重啟回預設）；`auto`＝回預設 |
| `!reset` | 清空此頻道記憶 |
| `!help` | 說明 |

**參考資料**：產檔指令可以**附上 .txt / .md / .docx / .pdf**，或用 Discord 的「回覆」回覆某則訊息，模型會以那些內容為準。
範例：回覆一則會議記錄訊息，輸入 `!ppt 整理成組會報告`。

**範本**：把實驗室的 `ppt_template.pptx`、`word_template.docx` 放進 [discord/client/templates/](../client/templates/README.md) 就會自動套用。

> 本地小模型產出的是**草稿**。參考文獻一律標為「[待補]」，模型被要求不可捏造文獻；數據和論述都請人工查證。

### 工具（function calling + MCP）

一般聊天時，bot 會把工具清單一起送給模型（OpenAI `tools` 參數），模型想用工具時 bot 執行後把結果餵回去，最多 `MAX_TOOL_ROUNDS` 輪。查資料時 Discord 只顯示一則「🔍 查資料中…」，答案出來後自動刪掉（`TOOL_STATUS=off` 不顯示）。
模型服務不接受 `tools` 參數時，bot 會自動退回一般聊天。

| 工具 | 來源 | 用途 | 需要 |
|------|------|------|------|
| `web_search` | 內建 | 網路搜尋（Google CSE，沒金鑰用 DuckDuckGo） | — |
| `get_weather` | 內建 | 目前天氣與 1~7 天預報（Open-Meteo，免金鑰） | — |
| `fetch` | `uvx mcp-server-fetch` | 讀網頁全文 | uv |
| `time` | `uvx mcp-server-time` | 現在時間、時區換算 | uv |
| `calculator` | `uvx mcp-server-calculator` | 精確計算 | uv |
| `wikipedia` | `uvx wikipedia-mcp` | 維基百科搜尋 / 摘要；預設關（主機上常查無結果、工具重複註冊 ~30 個；fetch 就能讀維基） | uv |
| `arxiv` | `uvx arxiv-mcp-server` | 搜尋 / 讀 arXiv 論文（存在 `data/arxiv/`） | uv |
| `memory` | `npx @modelcontextprotocol/server-memory` | 長期記憶（存在 `data/memory.jsonl`，**所有頻道與伺服器共用**） | Node.js 18+ |
| `context7` | `npx @upstash/context7-mcp` | 程式套件最新文件（免金鑰、有流量限制） | Node.js 18+ |
| `sequential-thinking` | `npx @modelcontextprotocol/server-sequential-thinking` | 逐步思考；預設關（Kimi 本身會思考） | Node.js 18+ |

- 全部免費、免金鑰。開關與參數在 [`mcp_servers.json`](../client/mcp_servers.json)，改完重啟 bot；找不到指令（例如沒裝 Node.js）的會自動略過。
- 第一次啟動時 uvx / npx 要下載套件，工具會在 bot 上線後 1~3 分鐘內陸續就緒（`!tools` 看狀態）。
- 安全：工具參數裡指向內網 / 本機的網址會被擋掉（`BLOCK_PRIVATE_URLS=1`），避免有人叫 bot 讀 vLLM 或實驗室內部服務。注意這只檢查參數裡的網址，擋不住外部網站轉址到內網。
### 技能庫（越用越會）

模型本身不會學習，但 bot 會把「好用的做法」存成技能，之後每次回答都把技能清單放進 system prompt，相關時模型會讀出來照做。

1. 有人教 bot 做法（例如「以後查活動先看官方日文新聞頁，記成技能」），或模型自己摸索出有效查法時，模型呼叫 `propose_skill` 提案。
2. bot 在頻道貼出提案內容並加上 ✅ ❌。**只有具「管理員」或「管理伺服器」權限的人按的才算**，一般成員按無效。
3. 核准後存成 `data/skills/<名稱>.md`，立即生效；同名提案＝修改既有技能。
4. 私訊裡無法核准（沒有管理員）。等待中的提案只存在記憶體，bot 重啟後要重新提案。
5. 管理員也可以直接編輯 `data/skills/` 裡的檔案，不用重啟。上限：每個技能 3000 字（`MAX_SKILL_CHARS`）、共 50 個（`MAX_SKILLS`）。
6. bot 要有「管理訊息」權限才能在審核完清掉 ✅ ❌；沒有也能正常運作。

- 不開 Discord 也能測：`.venv/bin/python selftest.py`（測 MCP）、`.venv/bin/python selftest.py --llm`（再用 `.env` 的模型實測工具呼叫）。

---

## 金鑰與換模型

bot 會自動讀主機的金鑰（Ubuntu 直接讀 `~/vllm-server/vllm.env`、Windows 從 WSL 讀）、自動使用 vLLM 目前的模型，所以主機換金鑰或換模型後**都不用改 bot 的設定**。
怎麼取得 / 更換金鑰、怎麼換模型並套進 opencode，請看 [完整步驟.md 第 5 章](../../完整步驟.md#5-日常管理管理者)。

**接遠端 gateway 時**：金鑰填在 `.env` 的 `LLM_API_KEY`（或 `deploy.sh --api-key`）；要指定模型用 `.env` 的 `LLM_MODEL`（或 `--model`）。在 Discord 也能用 `!models` 看清單、`!model <名稱>` 當場切換（本次執行有效，重啟後回到 `.env` 的 `LLM_MODEL`）。

---

## 設定（`.env`）

| 變數 | 說明 |
|------|------|
| `LLM_BASE_URL` | 模型服務位址，預設 `http://127.0.0.1:8000/v1`（deploy.sh / deploy.ps1 自動填；接遠端 gateway 用 `--remote` 設成外部網址） |
| `WSL_DISTRO` | 只有 Windows 用：vLLM 所在的 WSL 發行版（deploy.ps1 自動填） |
| `LLM_API_KEY` | 留空 = 自動讀主機的 vllm.env（建議，本地 vLLM）；**接遠端 gateway 時要填**該服務金鑰 |
| `LLM_MODEL` | 指定模型名稱；留空＝自動用 `/v1/models` 第一個（本地 vLLM 建議留空）；多模型 gateway 填要用的那個 |
| `SYSTEM_PROMPT` | bot 個性 |
| `MAX_HISTORY` / `HISTORY_MAX_CHARS` | 對話記憶則數和總字數上限（`deploy.sh --remote` 會從 10 / 8000 放大成 30 / 40000） |
| `LLM_THINKING` | `auto`（預設）＝本地 vLLM 關思考求快、遠端 gateway 保留思考；`off` / `on` 強制 |
| `ENABLE_TOOLS` | 1＝模型可呼叫工具（預設）；0＝只聊天 |
| `MAX_TOOL_ROUNDS` / `TOOL_RESULT_MAX_CHARS` | 每次回答最多幾輪工具、每個工具結果最多幾字 |
| `BLOCK_PRIVATE_URLS` | 擋掉工具存取內網 / 本機網址（預設 1） |
| `REF_MAX_CHARS` | 附件參考資料字數上限 |
| `TO_TRADITIONAL` | 自動簡轉繁（1/0） |
| `DOC_FONT_EA` / `DOC_FONT_LATIN` / `PPT_FONT` | 文件字型 |
| `ALLOWED_CHANNEL_ID` | 只在這個頻道 ID 自動回一般聊天（留空＝每個頻道都回，較吵；@bot／私訊／`!` 指令一律會回）。可用 `deploy.sh --channel` 設定 |
| `SEARCH_ENGINE` / `GOOGLE_API_KEY` / `GOOGLE_CSE_ID` | 聯網搜尋（沒設定時會自動改用 DuckDuckGo） |

## 疑難排解

| 症狀 | 處理 |
|------|------|
| Discord 顯示「連不上 vLLM」 | 主機執行 `vllmctl status`（Windows：雙擊 `server\wsl2\vllmctl.cmd`；Ubuntu：`bash ~/local-llm/server/vllm/vllmctl.sh status`）；沒在跑就 `start` |
| bot 沒上線（Ubuntu） | `journalctl -u discord-bot -n 30`：`LoginFailure` = token 貼錯；`PrivilegedIntentsRequired` = 沒開 MESSAGE CONTENT INTENT |
| 回答出現 `404` / 找不到模型 | `LLM_MODEL` 或 `!model` 指定的名稱在服務上不存在；用 `!models` 查正確名稱 |
| 接遠端 gateway 連不上 | 檢查 `.env` 的 `LLM_BASE_URL` / `LLM_API_KEY`；用 `curl -s <URL>/models -H "Authorization: Bearer <KEY>"` 測試 |
| 每則訊息被回兩次 | 兩台主機用了同一個 token：各建一個 Application，或停掉其中一台 |
| 顯示「API 金鑰錯誤」 | `.env` 的 `LLM_API_KEY` 清空，重啟 bot |
| 顯示「內容太長」 | `!reset` 清記憶，或縮短附件；常發生就調小 `REF_MAX_CHARS` |
| 回應很慢 | 同學正在大量使用 opencode（共用同一張顯卡），稍等即可；遠端 Kimi 開著思考 + 呼叫工具本來就要幾十秒 |
| `!tools` 顯示某個 server ❌ / ⏭️ | ⏭️ 找不到指令：裝 uv 或 Node.js 18+；❌ 看 `journalctl -u discord-bot -n 200` 裡 `[MCP]` 開頭 的錯誤 |
| `!tools` 說模型不支援工具 | gateway 沒開 tool calling；自架 vLLM 要加 `--enable-auto-tool-choice --tool-call-parser <對應模型>` |

## 檔案清單（都在 `discord/client/`）
| 檔案 | 用途 |
|------|------|
| `discord_bot.py` | Discord bot 本體（指令處理） |
| `llm_client.py` | 呼叫 vLLM、自動讀金鑰與模型、JSON 結構化輸出 |
| `agent.py` | 工具呼叫迴圈（模型 ↔ 工具） |
| `mcp_client.py` / `mcp_servers.json` | 連 MCP server、工具清單與設定 |
| `selftest.py` | 不開 Discord 測工具與模型 |
| `skills.py` | 技能庫（存取 `data/skills/`、提案驗證） |
| `data/` | 技能、長期記憶、arXiv 論文（不進 git） |
| `office_gen.py` | JSON schema、提示詞、pptx/docx/xlsx 排版 |
| `deploy.ps1` | Windows 筆電一鍵部署 |
| `deploy.sh` | Ubuntu 伺服器一鍵部署（含 systemd 服務 `discord-bot`） |
| `install-autostart.ps1` | Windows：bot 開機自動啟動 |
| `run-bot.ps1` / `start-bot.bat` | 手動啟動 bot |
| `templates/` | 實驗室自訂範本（選用） |
| `outputs/` | 產出的檔案（不進 git） |
