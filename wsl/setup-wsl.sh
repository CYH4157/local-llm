#!/usr/bin/env bash
# =============================================================================
#  setup-wsl.sh — 在 WSL2 (Ubuntu) 裡安裝 vLLM + llama-swap，並註冊成 systemd 服務
#
#  通常由 Windows 端的 deploy.ps1 呼叫；也可以在 Ubuntu 裡手動跑：
#      bash /mnt/c/Users/<你>/Documents/llm/local-llm/wsl/setup-wsl.sh
#
#  安裝位置：~/llm
#      ~/llm/.venv            vLLM 的 Python 環境
#      ~/llm/llama-swap       llama-swap 執行檔
#      ~/llm/llama-swap.yaml  模型設定（從專案的 wsl/llama-swap.yaml 複製）
#  服務：llama-swap.service（開機自動啟動，只監聽本機 127.0.0.1:8080）
# =============================================================================
set -euo pipefail

# deploy.ps1 會先把本檔轉成 LF 放到 /tmp 再執行，所以用 SRC_DIR 指回專案的 wsl/ 資料夾
SRC_DIR="${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APP_DIR="$HOME/llm"
PORT="${LLAMA_SWAP_PORT:-8080}"

step() { printf '\n\033[36m==== %s ====\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m  %s\n' "$1"; }

# --- 0. 檢查 GPU ------------------------------------------------------------
step "0. 檢查 GPU（WSL 靠 Windows 的 NVIDIA 驅動，不要在 Ubuntu 另裝驅動）"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "找不到 nvidia-smi：請更新 Windows 端 NVIDIA 驅動後，執行 wsl --shutdown 再試。" >&2
    exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
ok "GPU 可用"

# --- 1. 系統套件 ------------------------------------------------------------
step "1. 系統套件（需要輸入 Ubuntu 密碼）"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates build-essential
ok "完成"

# --- 2. uv + vLLM -----------------------------------------------------------
step "2. 安裝 uv 與 vLLM（約 5~8GB，較久）"
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$APP_DIR"
[ -d "$APP_DIR/.venv" ] || uv venv --python 3.12 "$APP_DIR/.venv"
uv pip install --python "$APP_DIR/.venv/bin/python" -U vllm --torch-backend=auto
"$APP_DIR/.venv/bin/vllm" --version
ok "vLLM 安裝完成"

# --- 3. llama-swap ----------------------------------------------------------
step "3. 安裝 llama-swap"
URL="$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
      | head -n1 | sed 's/.*"\(https[^"]*\)"/\1/')"
if [ -z "$URL" ]; then
    echo "抓不到 llama-swap 下載網址（GitHub API 可能限流），請稍後再試。" >&2
    exit 1
fi
TMP="$(mktemp -d)"
curl -fsSL "$URL" -o "$TMP/ls.tar.gz"
tar -xzf "$TMP/ls.tar.gz" -C "$TMP"
install -m 755 "$TMP/llama-swap" "$APP_DIR/llama-swap"
rm -rf "$TMP"
ok "$(basename "$URL")"

# 設定檔（去掉 Windows 換行，避免 CRLF 造成解析錯誤）
if [ -f "$APP_DIR/llama-swap.yaml" ] && ! cmp -s <(tr -d '\r' < "$SRC_DIR/llama-swap.yaml") "$APP_DIR/llama-swap.yaml"; then
    cp "$APP_DIR/llama-swap.yaml" "$APP_DIR/llama-swap.yaml.bak"
    warn "舊設定已備份成 llama-swap.yaml.bak"
fi
tr -d '\r' < "$SRC_DIR/llama-swap.yaml" > "$APP_DIR/llama-swap.yaml"
ok "設定檔：$APP_DIR/llama-swap.yaml"

# --- 4. systemd 服務 --------------------------------------------------------
step "4. 註冊 systemd 服務"
if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
    printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
    warn "已在 /etc/wsl.conf 開啟 systemd。請在 Windows 執行： wsl --shutdown"
    warn "然後重新執行本腳本（或 deploy.ps1）完成服務註冊。"
    exit 2
fi

# API 金鑰：優先用 deploy.ps1 傳進來的（來自 Windows 端 .env 的 LLM_API_KEY）
KEY_FILE="$APP_DIR/llama-swap.env"
KEY="${LLAMA_SWAP_API_KEY:-}"
if [ -z "$KEY" ] && [ -f "$KEY_FILE" ]; then
    KEY="$(sed -n 's/^LLAMA_SWAP_API_KEY=//p' "$KEY_FILE")"
fi
if [ -z "$KEY" ]; then
    KEY="sk-lab-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    warn "未提供金鑰，已自動產生：$KEY（請填到 Windows 端 .env 的 LLM_API_KEY）"
fi
( umask 077; printf 'LLAMA_SWAP_API_KEY=%s\n' "$KEY" > "$KEY_FILE" )
ok "API 金鑰已寫入 $KEY_FILE"
AUTH="Authorization: Bearer $KEY"

sudo tee /etc/systemd/system/llama-swap.service >/dev/null <<EOF
[Unit]
Description=llama-swap (vLLM model switcher)
After=network-online.target

[Service]
User=$USER
WorkingDirectory=$APP_DIR
Environment=PATH=$APP_DIR/.venv/bin:/usr/local/bin:/usr/bin:/bin
Environment=HF_HOME=$HOME/.cache/huggingface
EnvironmentFile=$KEY_FILE
ExecStart=$APP_DIR/llama-swap --config $APP_DIR/llama-swap.yaml --listen 127.0.0.1:$PORT --watch-config
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable llama-swap
sudo systemctl restart llama-swap
sleep 3
if curl -fsS -H "$AUTH" "http://127.0.0.1:$PORT/v1/models" >/dev/null; then
    ok "llama-swap 已啟動：http://localhost:$PORT/v1/models"
else
    warn "llama-swap 尚未回應，查看紀錄： journalctl -u llama-swap -n 50"
fi

# --- 5. 預先下載預設模型（可略過）------------------------------------------
step "5. 預先下載並測試預設模型（第一次約 6GB）"
if [ "${SKIP_WARMUP:-0}" = "1" ]; then
    warn "略過（SKIP_WARMUP=1）"
else
    DEFAULT_MODEL="${DEFAULT_MODEL:-qwen3-8b}"
    echo "  送出測試請求給 $DEFAULT_MODEL，等它下載+載入（可能要數分鐘）…"
    if curl -fsS -m 1200 "http://127.0.0.1:$PORT/v1/chat/completions" \
         -H 'Content-Type: application/json' -H "$AUTH" \
         -d "{\"model\":\"$DEFAULT_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"用一句話自我介紹\"}],\"max_tokens\":60}"; then
        echo
        ok "模型可以正常回應"
    else
        warn "測試失敗，查看紀錄： journalctl -u llama-swap -n 100"
        warn "多半是顯存不足：到 $APP_DIR/llama-swap.yaml 調小 --max-model-len"
    fi
fi

step "WSL 端完成"
echo "  服務狀態： sudo systemctl status llama-swap"
echo "  即時紀錄： journalctl -u llama-swap -f"
echo "  網頁介面： http://localhost:$PORT/ui （可看載入狀態 / 紀錄）"
