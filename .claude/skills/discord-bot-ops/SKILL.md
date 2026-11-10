---
name: discord-bot-ops
description: >-
  部署與維運 local-llm 的 Discord bot（discord/client）。Use when the user wants to
  deploy / 部署 / 啟動 / 常駐 this Discord bot on a server, invite it to a new Discord
  server (e.g. pikmin), switch between local vLLM and a remote OpenAI-compatible
  gateway (NCHC genai), list or change the gen model (!models / !model / LLM_MODEL),
  set which channel it auto-replies in (ALLOWED_CHANNEL_ID), or check / restart the
  `discord-bot` systemd service and read its logs.
---

# local-llm Discord bot 部署與維運

discord.py 寫的 bot,接 OpenAI 相容 API（本地 vLLM 或遠端 gateway）。程式在 `discord/client/`。
常駐方式:Ubuntu 用 systemd 服務 `discord-bot`（`Restart=always`,開機自啟+崩潰自動重拉）;
Windows 筆電用 `start-bot.bat` 或 `install-autostart.ps1`。

## 部署（Ubuntu 伺服器）

前置:`git`、`curl`（`deploy.sh` 會自動裝 `uv` 與 Python 3.12 venv）。

```bash
git clone https://github.com/CYH4157/local-llm.git ~/local-llm
cd ~/local-llm/discord/client
```

模型來源擇一:

- **本地 vLLM**（同一台已用 `server/vllm/setup-vllm.sh` 架好）:
  `bash deploy.sh --token <DISCORD_TOKEN>`
- **遠端 gateway**（例如 NCHC genai,不需本機 vLLM）:
  `bash deploy.sh --remote https://inner-medusa.genai.nchc.org.tw/v1 --api-key sk-xxxx --token <DISCORD_TOKEN>`
  gateway 掛多個模型時加 `--model <模型名>`。

不想把金鑰留在 shell history → 省略 `--api-key`,裝完 `nano .env` 填 `LLM_API_KEY`,再 `sudo systemctl restart discord-bot`。

加 `--channel <頻道ID>` 讓 bot 只在指定頻道自動回一般聊天（不加=每個頻道都回,多人伺服器會很吵）。
`bash deploy.sh --help` 看完整用法。

## .env 重點設定

- `DISCORD_BOT_TOKEN`:Discord Developer Portal → Bot → Reset Token。**必須在該頁開 MESSAGE CONTENT INTENT**,否則收不到訊息。
- `LLM_BASE_URL` / `LLM_API_KEY`:模型服務網址與金鑰（遠端模式必填金鑰;本地模式留空會自動讀 `~/vllm-server/vllm.env`）。
- `LLM_MODEL`:指定模型名稱。留空=自動用 `/v1/models` 第一個（本地 vLLM 建議留空）;多模型 gateway 填要用的那個。
- `ALLOWED_CHANNEL_ID`:**留空=每個頻道都自動回（多人伺服器會很吵）**;填一個頻道 ID=只在該頻道自動回,其他頻道要 @bot 或私訊才回。`!` 指令與被 @、私訊一律會回。
- 其他:`SYSTEM_PROMPT`、`MAX_HISTORY`、`SEARCH_ENGINE` + `GOOGLE_API_KEY`/`GOOGLE_CSE_ID`、字型 `DOC_FONT_*`/`PPT_FONT`。

## 日常維運

```bash
sudo systemctl status discord-bot      # 狀態
journalctl -u discord-bot -f           # 即時 log（看到「[已上線]」就成功）
sudo systemctl restart discord-bot     # 改完 .env 後重啟
bash deploy.sh --uninstall             # 移除服務（.env 與 .venv 保留）
```

## 查 / 換模型

- Discord 內:`!models` 列出可用模型、`!model <名稱>` 切換（本次執行有效,重啟回預設）、`!model auto` 取消指定、`!model` 看目前。
- 永久改預設:改 `.env` 的 `LLM_MODEL`,再 `restart`。
- 查 gateway 有哪些模型:`curl -s <LLM_BASE_URL>/models -H "Authorization: Bearer <KEY>" | python3 -m json.tool`。

## 邀 bot 進新伺服器（例如 pikmin）

1. Developer Portal → OAuth2 → URL Generator:scopes 勾 `bot`,權限至少 Send Messages、Read Message History、Attach Files,用產生的連結把 bot 邀進該伺服器。
2. 同一支 bot（同 token）可同時在多個伺服器;要完全獨立就另建一個 application + 新 token,再部署一份（同機可多開一個 systemd 服務,改服務名與資料夾）。
3. 進去後在該伺服器選一個頻道,把頻道 ID 填進 `ALLOWED_CHANNEL_ID`（Discord 設定開「開發者模式」→ 右鍵頻道 → 複製頻道 ID）,`restart`。

## 常見錯誤對照

- `LoginFailure` → `DISCORD_BOT_TOKEN` 貼錯。
- `PrivilegedIntentsRequired` → Developer Portal 沒開 MESSAGE CONTENT INTENT。
- 連不上模型 → 遠端 `LLM_BASE_URL`/`LLM_API_KEY` 錯,或本地 vLLM 沒起（`bash ~/local-llm/server/vllm/vllmctl.sh status`）。
- 回答出現 `404` → `LLM_MODEL` 或 `!model` 指定的名稱在服務上不存在,用 `!models` 查正確名稱。

## 關鍵檔案

- `discord/client/deploy.sh` — 部署腳本（`--remote` / `--api-key` / `--model` / `--no-service` / `--uninstall`）
- `discord/client/.env.example` — 所有設定項與說明
- `discord/client/discord_bot.py` — Discord 指令與事件（`on_message` 決定何時回應）
- `discord/client/llm_client.py` — 呼叫 LLM;`list_models()` / `current_model()` / `set_model()`
- `server/vllm/` — 本地 vLLM（`setup-vllm.sh`、`vllmctl`）
