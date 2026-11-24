# Discord Bot 從零開始：一個 prompt 到郎碧 XX 上線

這份文件用「白話＋指令」帶你從完全沒有東西，做到 Discord 伺服器裡有一隻會聊天的 bot。
內容是把實際做過的流程（nchc-bot → 四隻新 bot）重新整理，照順序執行即可。

適用環境：Ubuntu 伺服器（本文以 `ubuntu@140.110.146.187`、目錄 `~/local-llm` 為例）。

---

## 0. 先想清楚

- 這次的目標：讓大家輸入「一個 prompt」（例如「幫我部署郎碧01、郎碧02」）之後，做完這整份文件的事。
- 之後可以考慮把 deploy 文件直接寫進 prompt，讓 bot 上線更一條龍。

---

## 1. Open the VM：連上伺服器

從你的電腦（Windows PowerShell / Mac Terminal 都行）：

```powershell
ssh ubuntu@140.110.146.187
# 進去後
cd ~/local-llm
```

`local-llm` 是這個專案的 Git 倉庫，Discord bot 程式在 `discord/client/`。

---

## 2. Load the document：讓 AI 先讀文件

在 OpenCode（或你用來操作的 AI 工具）裡，先叫它讀這兩份：

1. `discord/doc/discord-bot.md`（主文件：架構、指令、維運）
2. `HANDOFF.md`（交接文件：目前進度、下一步）

這樣你和 AI 對「現在做到哪裡」會有共同理解。

---

## 3. Environment setup：Discord Bot 執行環境

### 3.1 看要用哪個 Python，先升級 pip

```bash
cd ~/local-llm/discord/client
python3 -m venv venv          # 建立虛擬環境（如果還沒有）
source venv/bin/activate
pip install --upgrade pip
```

### 3.2 照 requirements 裝套件

```bash
pip install -r requirements.txt
```

> `requirements.txt` 裡已經包含 `discord.py>=2.3`（就是 Discord Bot 用的套件），
> 所以跑一次這行就會把 discord、openai、python-dotenv 等全部裝齊，**不用另外下 `pip install discord`**。

---

## 4. Get a Discord Bot：到 Discord 開一隻 Bot

每一隻 bot（nchc-bot、郎碧01、郎碧02……）都要各自做一次：

1. 到 <https://discord.com/developers/applications> → **New Application**（取名例如「郎碧01」）。
2. 左邊 **Bot** → **Reset Token** 可拿到 token（只會顯示一次，請收好）。
3. 同一頁打開 **Message Content Intent**（一定要開，bot 才看得到訊息文字）。
4. 左邊 **OAuth2 → URL Generator**：
   - Scopes 勾 `bot`
   - 權限勾 `View Channels`、`Send Messages`、`Read Message History`、`Attach Files`
5. 複製產生的網址到瀏覽器打開，把 bot 邀請進你的伺服器。

---

## 5. Setup SystemD Service：讓 Ubuntu 一直幫你跑 Discord Bot

專案已經有現成腳本 `discord/client/deploy.sh`，會幫你做完「建環境檔 → 裝套件 → 註冊 systemd」。

### 5.1 無 token 模式（建議流程）

先把環境和服務準備好，但不含 token，服務會停在 `inactive (dead)`：

```bash
cd ~/local-llm/discord/client
bash deploy.sh --name langbi01 --no-service
bash deploy.sh --name langbi02 --no-service
```

### 5.2 你（管理者）親手填 token

```bash
nano .env.langbi01   # 把 DISCORD_BOT_TOKEN=______ 換成真 token
nano .env.langbi02
```

### 5.3 註冊並啟動服務

需要 sudo，在互動式 SSH 裡：

```bash
sudo -v   # 輸入一次密碼
bash deploy.sh --name langbi01 --yes
bash deploy.sh --name langbi02 --yes
```

之後服務名稱就是 `discord-bot-langbi01.service`、`discord-bot-langbi02.service`。

---

## 6. Misc：你會需要知道的事

### 如何看檔案與程式

```bash
cd ~/local-llm/discord/client
ls        # 看有哪些檔
cat deploy.sh
nano discord_bot.py   # 或 vi、code .
```

### 常用指令

```bash
# 看某隻 bot 狀態與 log
sudo systemctl status discord-bot-langbi01.service
journalctl -u discord-bot-langbi01.service -n 50 --no-pager

# 重啟 / 停止 / 開機不自啟
sudo systemctl restart discord-bot-langbi01.service
sudo systemctl stop    discord-bot-langbi01.service
sudo systemctl disable discord-bot-langbi01.service
```

### 頻道限制

- `.env.<名稱>` 裡的 `ALLOWED_CHANNEL_ID` 決定 bot 在哪個頻道「主動回一般聊天」。
- 不設 = 全部頻道都回。
- 其他頻道的 @提及、私訊、`!` 指令還是會回（這是目前程式設計）。

### 它現在的極限（還沒做的）

- 目前只會「聊天＋既有技能」，還沒有：
  - 讀取 Discord 裡的對話當 context（只用當則訊息）
  - 主動提醒看文件（只有被問才會提）
  - 把 Discord 對話存檔、之後再讀
- 這些是下一步，要另外開工。

---

## 7. 之後可能的優化

- **文件中加上 prompt 的做法**：把整份 deploy 文件（這份 + discord-bot.md）直接餵給 AI，
  讓它讀完就能依 prompt 直接執行部署，不用人工逐步下指令。
- 一條龍部署：輸入「部署郎碧03」→ 自動 .env → systemd → 啟動完成。
