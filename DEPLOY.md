# 正式部署手冊：Windows + WSL2 + vLLM（手動部署）

目標：在 Windows 裡用 WSL2 跑一個 Linux，裡面裝 **vLLM** 當高併發引擎，
接上 Discord bot，服務約 10 人。

> 這份是給你**親手打指令**用的。每個階段都有「✅ 檢查點」，過了再往下。
> 可先在**這台筆電**練習（筆電有 Windows + GPU），熟了再照同樣步驟上桌機。

---

## 架構

```
Windows（實體機，裝 NVIDIA 驅動）
 └─ WSL2 (Ubuntu)              ← 真正的 Linux 跑在這
      ├─ vLLM  (port 8000)      ← 引擎，OpenAI 相容 API
      │    └─ Qwen2.5-7B-Instruct-AWQ 模型
      └─ discord_bot.py         ← bot 也跑在 WSL 裡，連 localhost:8000
```
重點：**vLLM 和 bot 都跑在 WSL 裡**，bot 連 `localhost:8000` 最單純。

---

## 階段 A：裝 WSL2 + 確認顯卡（在 Windows 這邊做）

前提：Windows 已裝**最新版 NVIDIA 顯示卡驅動**（到 nvidia.com 下載）。
⚠️ 不要在 WSL 裡另外裝 Linux 版顯卡驅動——WSL 的 GPU 是靠 Windows 驅動提供的。

1. **系統管理員**開 PowerShell，執行：
   ```powershell
   wsl --install
   ```
   會自動裝好 WSL2 + Ubuntu，然後**重開機**。

2. 重開機後會自動跳出 Ubuntu 視窗，第一次要你設 **Linux 使用者名稱 + 密碼**（記住這組密碼，之後 `sudo` 會用）。

3. **✅ 檢查點：確認 WSL 裡看得到顯卡**。在 Ubuntu 終端機打：
   ```bash
   nvidia-smi
   ```
   有看到你的顯卡型號 = GPU 穿透成功 ✅。看不到就停下來先解決（多半是 Windows 驅動太舊）。

---

## 階段 B：準備 Python 環境（在 WSL Ubuntu 裡做）

以下都在 Ubuntu 終端機執行。

1. 更新系統：
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. 裝 Python 工具：
   ```bash
   sudo apt install -y python3-venv python3-pip git
   ```

3. 建一個資料夾和虛擬環境：
   ```bash
   mkdir -p ~/llm && cd ~/llm
   python3 -m venv .venv
   source .venv/bin/activate
   ```
   > 之後每次開新終端機要先 `cd ~/llm && source .venv/bin/activate`。
   > 看到提示字元前面有 `(.venv)` 就表示在虛擬環境裡。

---

## 階段 C：安裝並啟動 vLLM

1. 安裝 vLLM（會一起裝 PyTorch 等，**約 5~8GB，較久**）：
   ```bash
   pip install vllm
   ```

2. **✅ 檢查點**：確認裝好：
   ```bash
   vllm --version
   ```

3. 啟動 vLLM 伺服器（第一次會自動從 HuggingFace 下載模型 ~6GB）：
   ```bash
   vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \
     --port 8000 \
     --max-model-len 8192 \
     --gpu-memory-utilization 0.90
   ```
   參數說明：
   - `--max-model-len 8192`：單次對話長度上限，12GB 顯卡設這個較穩。
   - `--gpu-memory-utilization 0.90`：讓 vLLM 用到 90% 顯存（剩下留給系統）。
   看到 `Uvicorn running on http://0.0.0.0:8000` = 成功 ✅。**這個視窗要一直開著**。

4. **✅ 檢查點**：另開一個 Ubuntu 終端機，測 API：
   ```bash
   curl http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"Qwen/Qwen2.5-7B-Instruct-AWQ","messages":[{"role":"user","content":"你好"}]}'
   ```
   有回一段 JSON 就成功了。

> 註：vLLM 講的是 **OpenAI 格式的 API**（`/v1/chat/completions`），
> 跟 Ollama 的 `/api/chat` 不一樣，所以下面 bot 要小改一個函式。

---

## 階段 D：接上 Discord bot

1. 把 bot 檔案複製進 WSL（Windows 的 D 槽在 WSL 裡是 `/mnt/c/...`）：
   ```bash
   cp /mnt/c/Users/a9756/Documents/llm/local-llm/discord_bot.py ~/llm/
   cp /mnt/c/Users/a9756/Documents/llm/local-llm/.env ~/llm/
   pip install discord.py requests python-dotenv ddgs
   ```

2. 改 `~/llm/.env`（用 `nano ~/llm/.env` 編輯），改成指向 vLLM：
   ```
   BACKEND=vllm
   VLLM_BASE_URL=http://localhost:8000/v1
   MODEL=Qwen/Qwen2.5-7B-Instruct-AWQ
   ```
   （`DISCORD_BOT_TOKEN` 等其他設定保留。）

3. **改 bot 程式**：`discord_bot.py` 原本 `ollama_chat()` 是打 Ollama 的 API。
   加一個走 vLLM(OpenAI 格式) 的版本，並依 `BACKEND` 切換。把 `ollama_chat` 換成：
   ```python
   BACKEND       = os.getenv("BACKEND", "ollama").lower()
   VLLM_BASE_URL = os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1").rstrip("/")

   def ollama_chat(messages: list[dict]) -> str:
       msgs = [{"role": "system", "content": SYSTEM_PROMPT}] + messages
       if BACKEND == "vllm":
           r = requests.post(f"{VLLM_BASE_URL}/chat/completions",
                             json={"model": MODEL, "messages": msgs}, timeout=600)
           r.raise_for_status()
           return r.json()["choices"][0]["message"]["content"].strip()
       else:  # ollama
           r = requests.post(f"{OLLAMA_HOST}/api/chat",
                             json={"model": MODEL, "messages": msgs, "stream": False}, timeout=600)
           r.raise_for_status()
           return r.json()["message"]["content"].strip()
   ```
   > 差別只在：vLLM 回傳在 `choices[0].message.content`，Ollama 在 `message.content`。
   > 其他邏輯（!web、記憶、切訊息）完全不用動。

4. 啟動 bot：
   ```bash
   cd ~/llm && source .venv/bin/activate
   python3 discord_bot.py
   ```
   看到 `已上線` 就成功，去 Discord 測。

---

## 階段 E：讓它一直跑（正式機才需要）

測試時，兩個終端機開著（一個 vLLM、一個 bot）就好。正式上線要背景常駐：

**簡單法：用 tmux**
```bash
sudo apt install -y tmux
tmux new -s vllm      # 開一個工作階段跑 vLLM，按 Ctrl+b 再按 d 離開但保持執行
tmux new -s bot       # 再開一個跑 bot
tmux attach -s vllm   # 想回去看就 attach
```

**正規法：用 systemd 服務**（開機自動啟動、掛掉自動重啟）——要上正式機時我再給你寫好 service 檔。

---

## 常見問題

- **`nvidia-smi` 在 WSL 看不到卡** → Windows 的 NVIDIA 驅動太舊，去官網更新最新版。
- **vLLM 說顯存不夠 (OOM)** → 把 `--max-model-len` 調小（如 4096），或 `--gpu-memory-utilization` 調到 0.85。
- **模型下載很慢** → 正常，第一次要抓 ~6GB，之後會快取起來。
- **bot 連不上 vLLM** → 確認 vLLM 那個視窗還開著、`curl` 測得到。

---

## 對照：你現在的測試環境 vs 這份

| | 現在（筆電測試） | 這份（正式 ②） |
|---|---|---|
| 系統 | Windows 原生 | Windows + WSL2(Ubuntu) |
| 引擎 | Ollama | vLLM |
| 模型 | qwen2.5:7b | Qwen2.5-7B-Instruct-AWQ |
| bot 程式 | 同一支 `discord_bot.py` | 同一支，只改 `ollama_chat` 一個函式 |
| 多人併發 | 普通 | 強 |
