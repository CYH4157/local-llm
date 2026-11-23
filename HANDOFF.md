# Discord 多 Bot 與股市功能開發交接

> 更新日期：2026-11-24  
> 狀態：依使用者要求暫停；下次 session 由此文件接手。  
> 回覆與文件一律使用繁體中文（台灣用語）。

## 1. 目標

在遠端主機 `ubuntu@140.110.146.187:~/local-llm` 保留現有 `nchc-bot`，另外部署「花枝想問ㄉAI」的 4 支獨立 Discord bot。每支 bot 使用各自的 Discord Application、token、環境檔與 systemd 服務，不得重複使用同一 token 啟動多個服務。

其中 `stock` 需提供台股／美股近即時行情、中文公司名搜尋，以及每 30 分鐘推播財經新聞。

## 2. Bot、頻道與人設需求

| 實例 | 名稱／用途 | 限定頻道 ID | 人設與行為 |
| --- | --- | --- | --- |
| 預設 | `nchc-bot` | `1541471524735680678` | 保留現有服務與設定 |
| `novel` | 幫我寫小小說 | `1574256936424177745` | 小說家／輕小說人設；加入有其他成員的群組後須主動發言，等待回覆時不能毫無反應 |
| `webgame` | 教我學網站跟遊戲 | `1574257038408810546` | 新手網頁／遊戲開發教學人設 |
| `stock` | 韭菜花的股票日常 | `1574257090669715526` | 熱血股市反指標人設；提供行情與財經新聞推播 |
| `counselor` | 跟ai老師諮商一下 | `1574257436389548132` | 像朋友閒聊、傾聽與短回覆 |

## 3. 已確定的技術方案

- SSH 使用本機 `id_ed25519` 免密碼登入，搭配 `BatchMode=yes`、`ConnectTimeout=10`、`StrictHostKeyChecking=accept-new`。
- 4 支新 bot 分別使用 `.env.<實例>` 與 `discord-bot-<實例>` systemd 服務。
- 各實例的人設寫入自己的 `SYSTEM_PROMPT`；NCHC gateway 金鑰安全沿用預設 `.env`，不得輸出秘密。
- 採無 token 部署：先建立並停止服務，待使用者將 token 填入對應環境檔後再重啟。
- 最後產生一鍵部署腳本並以 `scp` 傳到遠端，由使用者 SSH 執行；腳本只提示輸入一次 `sudo` 密碼。
- 行情工具註冊為 `agent.Builtin`；新聞排程掛在 `Bot.setup_hook()`／`Bot.close()`。
- 只有 `stock` 設定 `STOCK_FEEDS_ENABLED=true`，推播頻道與 `ALLOWED_CHANNEL_ID` 對齊。
- 沿用 `requests`，RSS 以 Python 標準函式庫解析，不新增套件。
- 行情使用 Yahoo Finance v8 chart；新聞使用 Google News RSS。
- 不使用會回 `401 Unauthorized` 的 Yahoo v7 quote，也不使用已確認不可用的 udn／LTN RSS。
- 中文公司名透過 TWSE／TPEx 官方 OpenAPI 清單比對；拉丁字母查詢沿用 Yahoo v1 search。
- 非 ASCII 查詢若被 Yahoo 回 `400 Invalid Search Query` 類錯誤，視為空結果，不視為服務失敗。
- 台股清單只在成功時快取，預設 TTL 為 12 小時（`STOCK_LIST_CACHE_TTL`）；失敗回 `None`、不快取，下次重試。
- 中文名稱以 `unicodedata.normalize("NFKC")` 正規化；排序為完全相符、前綴、部分包含，最多回 5 筆。
- 台股候選只保留 4–6 位純數字代號，包含 `0050` 等 ETF，排除特別股及 7 位以上商品代號。
- 行情與新聞皆須標示來源時間、延遲及穩定性限制，並附非投資建議聲明。

## 4. 目前進度

### 已完成

- 已確認遠端倉庫位於 `main`，當時工作樹乾淨。
- 遠端預設 `.env` 存在；`discord-bot.service` 為 active。
- 預設 bot 為 `nchc-bot#6793`，使用 NCHC gateway 與 Kimi-K3。
- 已建立本機新檔 `discord/client/stockfeed.py`，目前 641 行，包含：
  - Yahoo v8 chart 行情查詢。
  - TWSE／TPEx 中文公司名清單與比對邏輯。
  - Yahoo v1 search 代號搜尋。
  - Google News RSS 新聞擷取。
  - `StockNewsBroadcaster` 新聞推播排程。
- `stockfeed.py` 已通過 `py_compile`。
- 已實測 `quote('2330')`、`quote('AAPL')`、`latest_news(limit=3)`，皆成功，輸出含來源時間與免責聲明。
- TWSE／TPEx OpenAPI 清單實測皆回 HTTP `200`；當時分別取得 1098 筆與 898 筆。
- 預設觀察清單包含 `^TWII`、`2330.TW`、`0050.TW`、`^GSPC`、`^IXIC`、`^SOX`、`NVDA`。
- 預設新聞推播間隔為 `_NEWS_INTERVAL_DEFAULT = 1800` 秒。

### 尚未完成

- `stockfeed.py` 的 `_normalize_name()` 尚未定義；`_tw_company_candidates()` 目前會引用它，需補成 NFKC 正規化並去除空白。
- `search_symbol()` 目前只查 Yahoo v1 search，尚未接入中文搜尋流程。需改為：
  1. CJK 查詢先查 `_STOCK_ALIASES`。
  2. 再查 `_tw_company_candidates()`。
  3. 最後才依情況走 Yahoo search。
- 尚未將行情工具、人設、頻道限制與新聞排程生命週期整合至 `discord/client/discord_bot.py`。
- 尚未更新 `discord/client/.env.example` 的 `stock` 設定範例。
- 尚未完成整合測試與部署腳本。
- 尚未部署 4 支新 bot；目前缺少它們的 Discord token。

## 5. 本機與遠端狀態

### 本機

- 專案：`C:\Users\a9756\Documents\local-llm`
- 分支：`discord-multi-instance`
- HEAD：`9b9e8d9`
- HEAD 說明：`deploy.sh --name` 多實例，一台跑多支不同人設 bot，各自使用 `.env.<名稱>` 與 `discord-bot-<名稱>` 服務。
- 暫停前 `git status --short` 只有：
  - `?? discord/client/stockfeed.py`
  - `?? _sf_test_out.txt`
- 其他既有變更已提交。
- `_sf_test_out.txt` 是本機 UTF-8 測試輸出，完成測試後應清理，不要誤提交。

### 遠端

- 主機：`ubuntu@140.110.146.187`
- 專案：`~/local-llm`
- NCHC gateway：`https://inner-medusa.genai.nchc.org.tw/v1`
- 預設環境檔：`/home/ubuntu/local-llm/discord/client/.env`
- `sudo -n true` 已確認失敗，因此部署腳本需由使用者 SSH 登入後執行並自行輸入密碼。

## 6. 下次 session 建議步驟

1. 先重新檢查本機分支、工作樹與 `stockfeed.py` 實際內容，確認沒有其他 session 的後續修改。
2. 補上 `_normalize_name()`，修改 `search_symbol()` 接入中文公司名清單。
3. 重測中文完全相符／前綴／部分包含、ETF、無結果、Yahoo 非 ASCII 錯誤，以及台股／美股行情與新聞。
4. 閱讀 `agent.py` 的 `Builtin` 工具規格及例外處理，再修改 `discord_bot.py` 接入行情工具、人設、頻道限制與新聞排程。
5. 更新 `.env.example`，以 `selftest.py` 在不啟動 Discord 的情況下測試工具及 LLM 工具呼叫。
6. 擴充或建立一鍵部署腳本，處理多實例環境檔、systemd、`--remote`、`--channel` 與無 token 部署；腳本先建服務但保持停止。
7. 將腳本以 `scp` 傳到遠端，請使用者 SSH 執行並輸入一次 `sudo` 密碼。
8. 使用者填入 4 組 token 後，逐一重啟並檢查服務、日誌、限定頻道與推播，確保原有 `nchc-bot` 不受影響。
9. 收尾時清理 `_sf_test_out.txt`，回報修改檔案與測試方式。不要自行 commit、push 或做其他 Git 變更操作，除非使用者明確要求並再次確認。

## 7. 相關檔案

- `discord/client/stockfeed.py`：新建立、尚未追蹤；目前有上述兩個中文搜尋缺口。
- `discord/client/discord_bot.py`：待接入工具、人設、頻道限制與排程生命週期。
- `discord/client/agent.py`：參考 `Builtin` 工具規格與工具呼叫例外處理。
- `discord/client/deploy.sh`：已有多實例基礎，待確認並補齊一鍵部署需求。
- `discord/client/.env.example`：待新增 `stock` 設定範例。
- `discord/client/selftest.py`：用於不啟動 Discord 的工具與 LLM 工具呼叫測試。
- `_sf_test_out.txt`：本機測試輸出，完成後清理。
- `HANDOFF.md`：本交接文件。

## 8. 安全與測試注意事項

- 絕不在聊天室、日誌摘要或交接文件顯示 Discord token、NCHC 金鑰、密碼或完整 `.env` 內容。
- 遠端 `.env` 只確認存在與權限；不要讀出或印出秘密。
- 使用者需在 Discord Developer Portal 建立 4 個 Application，並為各 bot 啟用 `MESSAGE CONTENT INTENT`。
- 部署完成後，token 由使用者填入各 `.env.<實例>` 再重啟服務。
- 免費公開行情與新聞來源可能延遲、限流或中斷，回覆與推播必須保留來源、時間、限制與非投資建議聲明。
- 本機 Python 為 `3.13.9`；PowerShell 中文輸出可能亂碼，測試時使用 `PYTHONIOENCODING=utf-8`、`python -X utf8`，必要時將輸出寫成 UTF-8 檔案。
