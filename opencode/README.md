# 自架 vLLM × opencode（Windows 實驗室版）

一台 **Windows 筆電** 用 WSL2 跑 [vLLM](https://github.com/vllm-project/vllm)，筆電與實驗室同學的電腦都用
[opencode](https://github.com/anomalyco/opencode) 連上它，寫程式、查資料、寫作業。模型與資料都留在實驗室，不經過雲端 API。

📖 **完整教學**：[docs/使用教學.md](docs/使用教學.md)（安裝、換模型、調參數、金鑰與 token、疑難排解）
📘 **含 Discord bot 的全部步驟**：[../完整步驟.md](../完整步驟.md)　·　同一台 vLLM 也供 repo 根目錄的 Discord bot 使用

## 快速開始

**筆電（主機，需 NVIDIA 顯卡、Windows 11 22H2+）**

1. 雙擊 **`host\setup-host.cmd`**（第一次會安裝 WSL，重開機後再雙擊一次）
2. 過程中輸入 Ubuntu 密碼；結束時記下印出的 **網址** 與 **API 金鑰**
3. 開新終端機 → `cd` 到專案資料夾 → `opencode`

**同學的電腦**

- Windows：雙擊 **`client\install-client.cmd`**，貼上網址與金鑰 → 開新終端機 → `opencode`
- Ubuntu：`bash client/install-client.sh --url http://筆電IP:8000/v1 --key 金鑰 --name laptop`

**日常管理（筆電）**：雙擊 **`host\vllmctl.cmd`**，輸入 `info` / `show` / `logs` / `preset` / `model` / `set` / `new-key` / `bench`

**同學在家**：先連學校 VPN，其他跟在實驗室一樣。第一次要把 VPN 網段加進防火牆：
`host\setup-host.cmd -SkipVllm -AllowFrom LocalSubnet,<VPN網段>`，見 [使用教學 10.2](docs/使用教學.md#102-在家透過學校-vpn-連線)

**校外合作者（選用）**：雙擊 **`host\funnel.cmd`**，輸入 `on` / `off` / `status` / `test`。用 Tailscale Funnel 公開成 HTTPS 網址，對方不用裝 Tailscale。
見 [使用教學 10.1](docs/使用教學.md#101-校外連線tailscale-funnel)

## 架構

```
 Windows 筆電（主機）                                   同學電腦（Windows / Ubuntu）
 ├─ WSL2 Ubuntu（mirrored 網路）└─ vLLM :8000  ◀──────── opencode
 ├─ opencode（終端機版 / 桌面版）
 └─ 排程 vLLM-WSL-KeepAlive、防火牆 TCP 8000（同網段）
```

## 預設模型（實驗室筆電 RTX 5070 Ti 12GB 實測）

| 組合 | 模型 | 上下文 | 單人速度 | 五人同時 |
|------|------|--------|----------|----------|
| **laptop（預設）** | Qwen3-4B-Instruct-2507-FP8 | 32k | 27.5 tok/s | 121 tok/s |
| quality | Qwen3-8B-AWQ | 32k | 26.9 tok/s | 98 tok/s |

8B 在實測中沒有比較好（寫程式驗證 3/6 錯、長文件慢一倍），所以預設用 4B。
比較細節見 [使用教學 7.5 實測比較](docs/使用教學.md#75-實測比較實驗室筆電)；換模型與調參數見 [第 7、8 章](docs/使用教學.md#7-換模型)。

## 資料夾

| 路徑 | 用途 |
|------|------|
| `host/` | 筆電（主機）：`setup-host.cmd` 安裝、`vllmctl.cmd` 管理、`wsl/` 在 WSL 裡執行的腳本 |
| `client/` | 同學電腦：`install-client.cmd`（Windows）、`install-client.sh`（Ubuntu）、全域規則檔 |
| `docs/` | 完整教學 |
