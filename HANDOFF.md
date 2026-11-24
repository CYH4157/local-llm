# Discord 多 Bot 部署交接

> 更新日期：2026-11-24  
> 狀態：PR #7 已合併；四 bot 第一階段部署流程（`deploy-all.sh`）已建好並更新文件，等使用者提供 4 支 bot 的 Discord token。  
> 回覆與文件一律使用繁體中文（台灣用語）。

## 1. 目標

在遠端主機 `ubuntu@140.110.146.187:~/local-llm` 保留現有 `nchc-bot`，另外部署 4 支獨立 Discord bot（`novel` / `webgame` / `stock` / `counselor`）。每支 bot 使用各自的 Discord Application、token、`.env.<實例>` 與 `discord-bot-<實例>` systemd 服務，不得重複使用同一 token。

第一階段只做：各 bot 基本聊天、各自 `SYSTEM_PROMPT` 人設、限定頻道。行情／中文搜尋／新聞推播屬第二階段（見第 6 節）。

## 2. Bot 一覽

| 實例 | 用途 | 限定頻道 ID | systemd 服務 |
| --- | --- | --- | --- |
| 預設 | nchc-bot（保留不動） | `1541471524735680678` | `discord-bot.service` |
| `novel` | 小說家、主動接話 | `1574256936424177745` | `discord-bot-novel.service` |
| `webgame` | 新手網站／小遊戲教學 | `1574257038408810546` | `discord-bot-webgame.service` |
| `stock` | 股市反指標（先聊天） | `1574257090669715526` | `discord-bot-stock.service` |
| `counselor` | 陪伴傾聽、短回覆 | `1574257436389548132` | `discord-bot-counselor.service` |

人設全文寫在 `discord/client/deploy-all.sh` 的 `BOTS` 區塊，部署時寫入各實例的 `SYSTEM_PROMPT`。

## 3. 目前狀態

- 本機 `main` 已包含 PR #7：API 金鑰安全強化、`SITE`、頻道可人設、RPM/TPM 設定（bot 內建預設 8/30000）、LLM 請求佇列、上傳檔改存 `.cache/discord-uploads` 並保留、`LLM_RPM/LLM_TPM` 前綴相容（仍相容 NCHC 金鑰）。
- `discord/client/deploy-all.sh` 已建好：四實例＋頻道＋人設，不經手 token；先建環境檔與 venv，sudo 可用才註冊／啟動服務。
- 文件已更新：`HANDOFF.md`、`discord/doc/discord-bot.md`（多實例與四 bot 章節）。
- 遠端最後盤點（2026-11-24）：
  - repo 為 `main@abd1ba3`；`deploy.sh` 為多實例版本；`discord-bot.service` enabled、active、running。
  - `.env.novel` / `.env.webgame` / `.env.stock` / `.env.counselor` 尚未建立；四個新服務尚未註冊。
  - `.env` 由 deploy.sh 重新產生過：含 `SITE=optimizer-discord`、預設頻道與人設、RPM/TPM；`DISCORD_BOT_TOKEN` 為空待使用者填。

## 4. 下一步

1. 使用者準備 4 支 bot 的 Discord token（本專案流程不經手 token 內容）。
2. 把 `deploy-all.sh` 傳到遠端同路徑後執行 `bash deploy-all.sh`：
   - 建立／更新 `.env.<實例>`（沿用 `.env` 的 LLM 設定；新實例 token 為佔位值，既有實例保留已填 token）。
   - sudo 可用時註冊並啟動四個服務；token 為空的服務保持停止並列出待填環境檔。
3. 使用者在遠端自行編輯四個 `.env.<實例>` 填入 token，再跑一次 `bash deploy-all.sh`。
4. 驗收：四服務 `is-active`、各頻道出現 `[已上線]`、限定頻道外不回一般聊天、回覆符合各別人設。

### 4.1 互動式 SSH 指令

```bash
cd ~/local-llm/discord/client
nano .env.novel        # 依序填四個 .env.<實例> 的 DISCORD_BOT_TOKEN
bash deploy-all.sh     # 註冊／重啟四個服務時會需要 sudo 密碼
journalctl -u discord-bot-novel -u discord-bot-webgame -u discord-bot-stock -u discord-bot-counselor -n 20 --no-pager
```

### 4.2 遠端更新方式（重點）

- 只傳本次需要的檔案，不做整包部署；Windows 產生的腳本先轉 LF 再傳。
- 先 `ssh 'mkdir -p ~/local-llm/discord/client'`，再將檔案複製到相同路徑。
- 部署完成後可用 `journalctl -u discord-bot-<實例> -n 50 --no-pager` 查看 `[已上線]` 與 `[LLM]` 日誌。

## 5. 限制與安全

- 不洩漏任何 token、API 金鑰或完整 `.env`；遠端檢查用 `systemctl show -p ... --value`、`ss -tlnp | awk '{print $4}'` 等只取狀態與數值的方式。
- 未經使用者同意，不 commit、push、pull，也不動非本任務的變更（目前工作樹另有 `M discord/client/stockfeed.py`、`D opencode/servers.example.json` 等既有狀態，保持原樣）。
- 任何動到 bot 程式的修改，同步前先跑遠端 Python 編譯檢查。
- 不破壞既有 `nchc-bot`（`discord-bot.service`）的服務與設定。

## 6. 第二階段（stockfeed）

- `discord/client/stockfeed.py` 已搭好台股／美股近即時行情、中文公司名搜尋，並預留新聞推播介面；**本階段尚未接通、不重寫、不測試**。
- 未來接通時：測試只用**模擬網路**與**模擬 Discord**，不新增套件（`requirement.txt` 凍結），有修改才跑測試，避免在主力機偷偷改壞線上環境。
