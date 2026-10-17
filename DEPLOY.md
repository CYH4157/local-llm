# 維運手冊：WSL2 + vLLM + llama-swap

安裝請先照 [README](README.md) 跑 `deploy.ps1`。這份整理的是**日常維運**與**疑難排解**。

## 常用指令

在 Windows PowerShell 執行（`wsl -e` 會在 Ubuntu 裡執行後面的指令）：

```powershell
wsl -e systemctl status llama-swap          # 服務狀態
$k = (Select-String '^LLM_API_KEY=' .env).Line.Split('=',2)[1]   # 讀出金鑰，下面的 curl 要用
wsl -e journalctl -u llama-swap -n 100      # 最近 100 行紀錄（vLLM 的錯誤也在這）
wsl -e sudo systemctl restart llama-swap    # 重啟服務
curl.exe -H "Authorization: Bearer $k" http://127.0.0.1:8080/v1/models   # 列出模型
curl.exe -H "Authorization: Bearer $k" http://127.0.0.1:8080/running     # 目前載入 GPU 的模型
```

瀏覽器開 http://localhost:8080/ui 是 llama-swap 的管理頁，可以看載入狀態和即時紀錄，也能手動卸載模型。

## 手動測試模型

```powershell
curl.exe http://127.0.0.1:8080/v1/chat/completions -H "Content-Type: application/json" -H "Authorization: Bearer $k" `
  -d '{\"model\":\"qwen3-8b\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}'
```

第一次呼叫某個模型時，會先下載（約 5~6GB）再載入，需要幾分鐘。之後切換大約 30~90 秒。

## 顯存（8GB）調校

`wsl/llama-swap.yaml` 裡每個模型的重點參數：

| 參數 | 作用 | 顯存不夠時 |
|------|------|-----------|
| `--max-model-len` | 單次對話（輸入 + 輸出）的 token 上限 | 調小（6144 → 4096） |
| `--gpu-memory-utilization` | vLLM 可用的顯存比例 | 0.92 → 0.88 |
| `--max-num-seqs` | 同時處理的請求數 | 4 → 2 |
| `--enforce-eager` | 不建 CUDA graph：啟動快、省顯存 | 保留 |

常見錯誤訊息：
- `No available memory for the cache blocks` / `CUDA out of memory`：模型加上下文放不下，照上表調整
- `max_model_len ... is larger than the maximum number of tokens that can be stored in KV cache`：調小 `--max-model-len`
- Discord 顯示「內容太長」：用 `!reset` 清除記憶，或縮小 `.env` 的 `HISTORY_MAX_CHARS` / `REF_MAX_CHARS`

改完 yaml 後重跑 `deploy.ps1`（會同步到 `~/llm/llama-swap.yaml`），或直接編輯 WSL 裡那份。llama-swap 會自動重新載入設定。

## 為什麼要「WSL 常駐」排程？

WSL2 在 Windows 端沒有任何程序連著的時候，會自動關閉整個 Linux，裡面的 llama-swap 服務也會一起停。
`install-autostart.ps1` 註冊的 `LocalLLM-WSL-KeepAlive` 排程會在背景執行 `sleep infinity`，讓 WSL 一直保持運行。

## 換到其他機器（例如 12GB/16GB 桌機）

1. 同樣先裝 WSL2，再跑 `deploy.ps1`
2. 顯存變大後，可以調大 `wsl/llama-swap.yaml` 的 `--max-model-len`，或加入 14B 模型（例如 `Qwen/Qwen3-14B-AWQ`，建議 16GB 以上）
3. 多台機器要分流時，前面再加一層 LiteLLM 或 nginx；bot 只需要改 `LLM_BASE_URL`

## 安全性

- llama-swap 一律需要 API 金鑰（`.env` 的 `LLM_API_KEY`）。金鑰在 WSL 裡存成 `~/llm/llama-swap.env`（權限 600），由 systemd 帶入
- llama-swap 只監聽 `127.0.0.1:8080`，只給本機的 Discord bot 用。WSL 就算是 mirrored 網路（opencode 專案會開），區網也連不到
- 換金鑰：清空 `.env` 的 `LLM_API_KEY` → `deploy.ps1 -SkipWarmup` → 重啟 bot
