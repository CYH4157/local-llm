# 實驗室本地 LLM：vLLM × opencode × Discord

一台 **Windows 筆電**用 WSL2 跑 [vLLM](https://github.com/vllm-project/vllm)，實驗室成員可以：

- 用 **[opencode](https://github.com/anomalyco/opencode)** 寫程式、查資料、寫作業（每台電腦都能裝，不需要顯卡）
- 在 opencode 用 `/slides`、`/pdf2word`、`/official`、`/expense` 等指令做投影片、PDF 轉 Word、寫簽呈公文、整理核銷明細（[使用教學 5.5](opencode/doc/使用教學.md#55-文件與行政指令做投影片pdf-轉-word簽呈)）
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
| **管理者：架主機** | 雙擊 `server\wsl2\setup-host.cmd` → 記下網址與金鑰 |
| **管理者：架 Discord bot** | `discord\client\deploy.ps1` → `.env` 填 Discord token → `install-autostart.ps1` |
| **管理者：Ubuntu 伺服器架 Discord bot** | `bash discord/client/deploy.sh --token <Discord_bot_token>`（systemd 服務 `discord-bot`） |
| **同學：裝 opencode** | 雙擊 `opencode\client\install-client.cmd` → 貼上網址與金鑰 → `opencode` |
| **同學在家** | 先連學校 VPN，其他同上 |
| **日常管理** | 雙擊 `server\wsl2\vllmctl.cmd`：`info` / `logs` / `preset` / `new-key` / `bench` |
| **解除安裝** | 主機：`server\wsl2\uninstall-host.cmd`（還原原本設定）；同學：`opencode\client\uninstall-client.cmd` |

## 資料夾

```
local-llm/
├─ server/                 伺服器（有 NVIDIA 顯卡的那台）
│  ├─ wsl2/                Windows 主機：雙擊 setup-host.cmd 安裝、vllmctl.cmd 管理、funnel.cmd 校外連線
│  └─ vllm/                Linux 端的 vLLM 腳本（WSL2 或 Ubuntu 主機直接執行 setup-vllm.sh、vllmctl.sh）
├─ opencode/               寫程式、查資料用的 opencode
│  ├─ client/              同學的電腦：雙擊 install-client.cmd 安裝（含文件工具 labdoc 與 /指令）
│  ├─ servers.example.json 伺服器清單範本（管理者複製成 servers.json、填好金鑰再發給同學）
│  └─ doc/                 說明文件（使用教學.md）
├─ discord/                Discord bot（問答、產生 PPT / Word / Excel）
│  ├─ client/              bot 程式：deploy.ps1 部署、start-bot.bat 啟動、templates/ 範本
│  └─ doc/                 說明文件（discord-bot.md）
├─ docs/                   投影片與產生腳本 build_slides.py
└─ 完整步驟.md             第一次部署從這裡開始
```

| 說明文件 | 內容 |
|---|---|
| [完整步驟.md](完整步驟.md) | 從架設到日常管理的所有步驟（**第一次部署請看這份**） |
| [opencode/doc/使用教學.md](opencode/doc/使用教學.md) | vLLM 與 opencode 的完整說明：安裝參數、換模型、調參數、疑難排解 |
| [discord/doc/discord-bot.md](discord/doc/discord-bot.md) | Discord bot 的安裝、指令與設定 |
| [discord/client/templates/README.md](discord/client/templates/README.md) | 實驗室 PPT / Word 範本（選用） |

## 預設模型（實驗室筆電 RTX 5070 Ti 12GB 實測）

**Qwen3-4B-Instruct-2507-FP8，32k 上下文**：單人 27.5 tok/s，五人同時總吞吐 121 tok/s。
實測 8B 沒有比較好（寫程式驗證錯一半、長文件慢一倍）。8GB 顯卡請用 `small` 組合（4B · 16k）。
