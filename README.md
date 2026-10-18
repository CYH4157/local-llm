# 實驗室本地 LLM：vLLM × opencode × Discord

一台 **Windows 筆電**用 WSL2 跑 [vLLM](https://github.com/vllm-project/vllm)，實驗室成員可以：

- 用 **[opencode](https://github.com/anomalyco/opencode)** 寫程式、查資料、寫作業（每台電腦都能裝，不需要顯卡）
- 在 **Discord** 問答，並產生 **PowerPoint / Word / Excel** 草稿（研究計畫、投影片、課堂報告）

模型、程式碼與對話都留在實驗室，不經過雲端 API。

📘 **[完整步驟.md](完整步驟.md)**：從架設到日常管理的所有步驟　·　📊 **[投影片](docs/實驗室本地LLM使用教學.pptx)**

## 架構

```
 Windows 筆電（主機）
 ├─ WSL2 Ubuntu
 │   └─ vLLM :8000（需 API 金鑰）◀─┬─ opencode（筆電本機）
 │                                  ├─ Discord bot（本 repo 根目錄）
 │                                  ├─ 實驗室同學的 opencode（區網 IP）
 │                                  ├─ 在家的同學（先連學校 VPN，再用區網 IP）
 │                                  └─ 校外合作者（Tailscale Funnel，HTTPS）
 └─ 排程：WSL 常駐、bot 常駐
```

## 快速開始

| 誰 | 做什麼 |
|---|---|
| **管理者：架主機** | 雙擊 `opencode\host\setup-host.cmd` → 記下網址與金鑰 |
| **管理者：架 Discord bot** | `deploy.ps1` → `.env` 填 Discord token → `install-autostart.ps1` |
| **同學：裝 opencode** | 雙擊 `opencode\client\install-client.cmd` → 貼上網址與金鑰 → `opencode` |
| **同學在家** | 先連學校 VPN，其他同上 |
| **日常管理** | 雙擊 `opencode\host\vllmctl.cmd`：`info` / `logs` / `preset` / `new-key` / `bench` |

## 資料夾

| 位置 | 內容 | 說明文件 |
|---|---|---|
| `opencode/host/` | 主機：安裝、管理（vllmctl）、校外公開（funnel） | [opencode/docs/使用教學.md](opencode/docs/使用教學.md) |
| `opencode/client/` | 同學電腦的 opencode 安裝程式 | 同上 |
| 根目錄 `discord_bot.py` 等 | Discord bot | [docs/discord-bot.md](docs/discord-bot.md) |
| `templates/` | 實驗室 PPT / Word 範本（選用） | [templates/README.md](templates/README.md) |
| `docs/` | 投影片與產生腳本 `build_slides.py` | — |

## 預設模型（實驗室筆電 RTX 5070 Ti 12GB 實測）

**Qwen3-4B-Instruct-2507-FP8，32k 上下文**：單人 27.5 tok/s，五人同時總吞吐 121 tok/s。
實測 8B 沒有比較好（寫程式驗證錯一半、長文件慢一倍）。8GB 顯卡請用 `small` 組合（4B · 16k）。
