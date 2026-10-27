#!/usr/bin/env bash
# =============================================================================
#  setup-vllm.sh — 在 Ubuntu（筆電或伺服器）安裝 vLLM，註冊成 systemd 服務 vllm
#
#  用法：
#      bash setup-vllm.sh                       # 依 GPU 自動挑模型與參數
#      bash setup-vllm.sh --preset laptop       # small / laptop / quality / medium / large / xlarge
#      bash setup-vllm.sh --model Qwen/Qwen3-8B-AWQ --name qwen3-8b --max-len 16384 --tool-parser hermes
#
#  參數：
#      --preset NAME       small(8~10GB) / laptop(11~15GB) / quality / medium(16~45GB) / large(46~99GB) / xlarge(100GB+)
#
#  依 GPU 自動調整（不用手動設定）：
#      顯存     → 模型組合：RTX 4070 Laptop 8GB=small、RTX 4070 / 5070 Ti 12GB=laptop、H100-20C vGPU=medium、
#                 H100 80GB=large、H200 141GB=xlarge
#      架構     → 注意力後端：沒有 CUDA Toolkit 時，RTX 50（Blackwell）、以及 RTX 30/40 用 FP8 KV cache 時用 Triton；
#                 H100 / H200 交給 vLLM 選 FlashAttention
#                 RTX 30 / A100（沒有 FP8 硬體）KV cache 不用 FP8
#      驅動版本 → 驅動只到 CUDA 12.x（例如 vGPU）時裝 vLLM 的 CUDA 12.9 版
#      --model  HF_ID      自訂 Hugging Face 模型（搭配 --name / --max-len / --tool-parser）
#      --name   NAME       對外的模型名稱（opencode 裡看到的名字）
#      --max-len N         上下文長度
#      --tool-parser P     tool calling 解析器（Qwen 系列：hermes；Qwen3-Coder：qwen3_coder）
#      --extra "ARGS"      額外的 vllm serve 參數（例："--tensor-parallel-size 2"）
#      --port N            API 埠號（預設 8000）
#      --host ADDR         綁定位址（預設 0.0.0.0；只給本機用就填 127.0.0.1）
#      --key KEY           指定 API 金鑰（預設：沿用舊的，沒有就自動產生）
#      --hf-token TOKEN    下載需要授權的模型（Llama、Gemma…）時使用
#      --no-warmup         不預先下載 / 測試模型
#
#  安裝位置：~/vllm-server
#      .venv/          vLLM 的 Python 環境
#      vllm.env        模型 / 埠號 / 金鑰（改完：sudo systemctl restart vllm）
#      run-vllm.sh     systemd 呼叫的啟動腳本
#  重新執行本腳本是安全的：沒給參數時會沿用 vllm.env 的設定，只更新 vLLM 版本與服務。
# =============================================================================
set -Eeuo pipefail
# 指令意外失敗時印出是哪一行，不會沒有訊息就結束（例：新版驅動 nvidia-smi 的輸出格式改了）
trap 'printf "  \033[31m[X]\033[0m  第 %s 行執行失敗：%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

PRESET="" MODEL="" NAME="" MAX_LEN="" TOOL_PARSER="" EXTRA="" EXTRA_SET=0
PORT="" HOST="" KEY="" HF_TOKEN_ARG="" WARMUP=1
while [ $# -gt 0 ]; do
    case "$1" in
        --preset)      PRESET="$2"; shift 2 ;;
        --model)       MODEL="$2"; shift 2 ;;
        --name)        NAME="$2"; shift 2 ;;
        --max-len)     MAX_LEN="$2"; shift 2 ;;
        --tool-parser) TOOL_PARSER="$2"; shift 2 ;;
        --extra)       EXTRA="$2"; EXTRA_SET=1; shift 2 ;;
        --port)        PORT="$2"; shift 2 ;;
        --host)        HOST="$2"; shift 2 ;;
        --key)         KEY="$2"; shift 2 ;;
        --hf-token)    HF_TOKEN_ARG="$2"; shift 2 ;;
        --no-warmup)   WARMUP=0; shift ;;
        -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
        *) die "不認得的參數：$1（看說明：bash $0 --help）" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "請用一般使用者執行（需要時腳本會自己呼叫 sudo）"

IS_WSL=0
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1

# --- 0. GPU 驅動 ------------------------------------------------------------
step "0. 檢查 NVIDIA 驅動$([ "$IS_WSL" = 0 ] || echo '（WSL：使用 Windows 端的驅動）')"
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    if [ "$IS_WSL" = 1 ]; then
        die "WSL 裡看不到 GPU：請在 Windows 安裝 / 更新 NVIDIA 驅動，執行 wsl --shutdown 後再試（不要在 WSL 裡另外裝驅動）"
    fi
    warn "找不到可用的 NVIDIA 驅動，開始安裝（ubuntu-drivers）…"
    sudo apt-get update -y
    sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers install
    warn "驅動已安裝，請重新開機（sudo reboot）後再執行一次本腳本。"
    warn "若有開 Secure Boot，開機時會出現 MOK 畫面，選 Enroll MOK 並輸入剛剛設定的密碼。"
    exit 2
fi
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
gpu_detect
ok "GPU 可用：$GPU_NAME（$GPU_ARCH，compute $GPU_CC，$((GPU_MEM_MIB / 1024)) GB）"
[ "${GPU_COUNT:-1}" -le 1 ] || warn "偵測到 $GPU_COUNT 張 GPU，預設只用第一張；要合併使用：--extra \"--tensor-parallel-size $GPU_COUNT\""
case "${GPU_CC%%.*}" in 7) warn "$GPU_ARCH 顯卡較舊，vLLM 部分功能不支援；建議至少 RTX 30 系列" ;; esac

# systemd：vLLM 要註冊成服務。WSL 預設沒開，開啟後要 wsl --shutdown 重啟才生效
if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
    [ "$IS_WSL" = 1 ] || die "這台 Ubuntu 沒有使用 systemd，無法註冊服務"
    grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null || printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
    warn "已在 /etc/wsl.conf 開啟 systemd，請在 Windows 執行 wsl --shutdown 後再執行一次本腳本"
    exit 2
fi
# local-llm 專案的 llama-swap 也會用同一張 GPU
if systemctl is-active --quiet llama-swap 2>/dev/null; then
    warn "偵測到 llama-swap 服務（local-llm 專案）也在使用 GPU；兩邊同時載入模型會顯存不足。"
    warn "只用 opencode 的話可先停用它：sudo systemctl disable --now llama-swap"
fi

# --- 1. 系統套件 ------------------------------------------------------------
step "1. 系統套件"
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates build-essential python3 python3-dev jq
ok "完成"

# --- 2. uv + vLLM -----------------------------------------------------------
step "2. 安裝 / 更新 uv 與 vLLM（第一次約 5~8GB）"
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$APP_DIR"
[ -d "$APP_DIR/.venv" ] || uv venv --python 3.12 "$APP_DIR/.venv"
# PyPI 上的 vLLM 是 CUDA 13 版，需要 580 以上的驅動；驅動只到 CUDA 12.x（例如 vGPU）時改裝 GitHub 上的 +cu129 版
# 先讀 nvidia-smi 表頭的「CUDA Version: 13.1」；新版驅動格式不同抓不到時，改用驅動版本推算（580 以上 = CUDA 13）
DRIVER_VER="$(smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ' || true)"
DRIVER_CUDA="$(smi 2>/dev/null | sed -n 's/.*CUDA Version:[^0-9]*\([0-9][0-9]*\)\..*/\1/p' | head -n1 || true)"
if [ -z "$DRIVER_CUDA" ]; then
    if [ "${DRIVER_VER%%.*}" -ge 580 ] 2>/dev/null; then DRIVER_CUDA=13; else DRIVER_CUDA=12; fi
fi
ok "驅動 ${DRIVER_VER:-未知}，支援 CUDA $DRIVER_CUDA"
if [ "$DRIVER_CUDA" -ge 13 ]; then
    # 固定 cu130（PyPI 的 vLLM 就是用 CUDA 13.0 編的）：--torch-backend=auto 會照驅動挑最新的 CUDA，
    # 驅動支援 13.2（例：RTX 4070 + 610 驅動）時 PyTorch 裝成 cu132、TorchAudio 卻只有 cu130 → vLLM 啟動就報 CUDA 版本不一致
    TORCH_CUDA="$("$APP_DIR/.venv/bin/python" -c 'import torch; print(torch.version.cuda or "")' 2>/dev/null || true)"
    REINSTALL=()
    if [ -n "$TORCH_CUDA" ] && [ "$TORCH_CUDA" != "13.0" ]; then
        warn "已安裝的 PyTorch 是 CUDA $TORCH_CUDA 版，重裝成 CUDA 13.0 版（跟 vLLM、TorchAudio 一致）"
        REINSTALL=(--reinstall-package torch --reinstall-package torchaudio --reinstall-package torchvision)
    fi
    uv pip install --python "$APP_DIR/.venv/bin/python" -U vllm --torch-backend=cu130 "${REINSTALL[@]}"
else
    # 不是每一版都有 +cu129 檔案，從最近的正式版往回找第一個有的
    WHEEL_URL="$(curl -fsSL 'https://api.github.com/repos/vllm-project/vllm/releases?per_page=30' \
        | jq -r --arg arch "$(uname -m)" '[.[] | select(.prerelease | not) | .assets[]
            | select(.name | test("\\+cu129-cp38-abi3-manylinux_[0-9_]+_" + $arch + "\\.whl$")) | .browser_download_url][0] // empty')"
    [ -n "$WHEEL_URL" ] || die "找不到 vLLM 的 CUDA 12.9 版（GitHub API 連不上？）"
    warn "驅動只支援到 CUDA $DRIVER_CUDA，改裝 vLLM 的 CUDA 12.9 版：$(basename "$WHEEL_URL")"
    uv pip install --python "$APP_DIR/.venv/bin/python" -U --torch-backend=cu129 "$WHEEL_URL"
fi
"$APP_DIR/.venv/bin/vllm" --version
ok "vLLM 安裝完成"

# --- 3. 設定檔 vllm.env -----------------------------------------------------
step "3. 產生設定 $ENV_FILE"
# 先讀舊設定當預設值（重跑腳本不會蓋掉你手動改過的東西）
if [ -f "$ENV_FILE" ]; then
    load_env
    ok "沿用既有設定（模型：$SERVE_MODEL）"
fi

if [ -n "$PRESET" ] || { [ -z "$MODEL" ] && [ -z "${SERVE_MODEL:-}" ]; }; then
    [ -n "$PRESET" ] || PRESET="$(auto_preset)"
    apply_preset "$PRESET"
    ok "使用預設組合 $PRESET（$GPU_NAME，顯存 $GPU_MEM_MIB MiB）"
    SERVE_MODEL="$PRESET_MODEL"; SERVE_NAME="$PRESET_NAME"; SERVE_MAX_LEN="$PRESET_MAX_LEN"
    SERVE_GPU_UTIL="$PRESET_GPU_UTIL"; SERVE_TOOL_PARSER="$PRESET_TOOL_PARSER"; SERVE_EXTRA_ARGS="$PRESET_EXTRA"
fi
if [ -n "$MODEL" ]; then
    SERVE_MODEL="$MODEL"
    SERVE_NAME="${NAME:-$(basename "$MODEL" | tr '[:upper:]' '[:lower:]')}"
    SERVE_MAX_LEN="${MAX_LEN:-16384}"
    SERVE_GPU_UTIL="${SERVE_GPU_UTIL:-0.90}"
    SERVE_TOOL_PARSER="${TOOL_PARSER:-hermes}"
    [ "$EXTRA_SET" = 1 ] || SERVE_EXTRA_ARGS="$(gpu_tune_extra "$BASE_EXTRA")"
fi
[ -z "$NAME" ]        || SERVE_NAME="$NAME"
[ -z "$MAX_LEN" ]     || SERVE_MAX_LEN="$MAX_LEN"
[ -z "$TOOL_PARSER" ] || SERVE_TOOL_PARSER="$TOOL_PARSER"
[ "$EXTRA_SET" = 0 ]  || SERVE_EXTRA_ARGS="$EXTRA"
# 顯存已被其他程式占用時（Windows 桌面、瀏覽器…），自動調低 SERVE_GPU_UTIL，保留 1GB 緩衝
read -r MEM_TOTAL MEM_USED < <(nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits | head -n1 | tr -d ',')
# 重新執行本腳本時 vLLM 服務可能正在跑：它自己佔的顯存不能算成「其他程式」，否則會被誤調到最低
OWN_MEM=0; OWN_UNKNOWN=0
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    while IFS=, read -r pid mem; do
        pid="${pid//[[:space:]]/}"; mem="${mem//[[:space:]]/}"
        grep -q "/$SERVICE.service" "/proc/$pid/cgroup" 2>/dev/null || continue
        if [[ "$mem" =~ ^[0-9]+$ ]]; then OWN_MEM=$((OWN_MEM + mem)); else OWN_UNKNOWN=1; fi
    done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
    # WSL 的 nvidia-smi 看不到各程序用量（[N/A]）→ 無法區分，沿用原本的 SERVE_GPU_UTIL
    [ "$OWN_MEM" -gt 0 ] || OWN_UNKNOWN=1
fi
MEM_USED=$((MEM_USED - OWN_MEM))
MAX_UTIL="$(python3 -c "t,u=$MEM_TOTAL,$MEM_USED; print(max(0.30, int((t-u-1024)/t*20)/20))")"
if [ "$OWN_UNKNOWN" = 1 ]; then
    warn "vLLM 服務正在執行、無法分辨它佔用的顯存，SERVE_GPU_UTIL 維持 $SERVE_GPU_UTIL（重啟後若顯存不足：vllmctl set SERVE_GPU_UTIL 0.80）"
elif python3 -c "import sys; sys.exit(0 if $SERVE_GPU_UTIL > $MAX_UTIL else 1)"; then
    warn "GPU 已被其他程式使用 ${MEM_USED} MiB / ${MEM_TOTAL} MiB，SERVE_GPU_UTIL 由 $SERVE_GPU_UTIL 調低為 $MAX_UTIL"
    SERVE_GPU_UTIL="$MAX_UTIL"
fi
# 注意力後端：auto = 每次啟動依 GPU 決定（run-vllm.sh）；舊版腳本自動寫入的空白 / TRITON_ATTN 一律改成 auto，
# 否則 RTX 50 筆電上用的 Triton 會被帶到 H100 / H200（實測 H200 卡住、生成 0 token/s）
case "${SERVE_ATTN_BACKEND-}" in
    ""|TRITON_ATTN)
        [ -z "${SERVE_ATTN_BACKEND-}" ] || warn "注意力後端由 TRITON_ATTN 改成 auto（依 GPU 自動選）"
        SERVE_ATTN_BACKEND=auto ;;
esac
ATTN_NOW="$(auto_attn_backend "${SERVE_EXTRA_ARGS:-}")"
ok "注意力後端：auto → ${ATTN_NOW:-FlashAttention（vLLM 自動選）}"
SERVE_PORT="${PORT:-${SERVE_PORT:-8000}}"
SERVE_HOST="${HOST:-${SERVE_HOST:-0.0.0.0}}"
SERVE_API_KEY="${KEY:-${SERVE_API_KEY:-$(gen_key)}}"
HF_TOKEN="${HF_TOKEN_ARG:-${HF_TOKEN:-}}"

# 寫進雙引號字串前先跳脫特殊字元（SERVE_EXTRA_ARGS 可能含 JSON）
esc() { printf '%s' "$1" | sed -e 's/[\\"$`]/\\&/g'; }
( umask 077; cat > "$ENV_FILE" <<EOF
# vLLM 服務設定 — 改完執行：sudo systemctl restart vllm
# （刻意用 SERVE_ 開頭，避免和 vLLM 自己的 VLLM_PORT 等環境變數衝突）

# Hugging Face 模型 ID 與對外名稱（opencode 裡選的就是 SERVE_NAME）
SERVE_MODEL="$SERVE_MODEL"
SERVE_NAME="$SERVE_NAME"

# 上下文長度：opencode 至少要 16k 才好用；顯存不足（OOM / KV cache 不夠）就調小
SERVE_MAX_LEN="$SERVE_MAX_LEN"
# 顯存使用比例：同一張卡還要跑桌面或其他程式時調低（如 0.85）
SERVE_GPU_UTIL="$SERVE_GPU_UTIL"
# tool calling 解析器（opencode 必需）：Qwen2.5/Qwen3 → hermes，Qwen3-Coder → qwen3_coder
SERVE_TOOL_PARSER="$SERVE_TOOL_PARSER"
# 其他 vllm serve 參數，例：--tensor-parallel-size 2（兩張 GPU）
SERVE_EXTRA_ARGS="$(esc "$SERVE_EXTRA_ARGS")"
# 注意力運算後端：auto = 依 GPU 自動選（沒有 CUDA Toolkit 時：RTX 50、或 RTX 30/40 用 FP8 KV cache → TRITON_ATTN；H100 / H200 交給 vLLM）；
#   也可以指定 FLASH_ATTN / FLASHINFER / TRITON_ATTN；空白 = 完全交給 vLLM
SERVE_ATTN_BACKEND="$SERVE_ATTN_BACKEND"

SERVE_HOST="$SERVE_HOST"
SERVE_PORT="$SERVE_PORT"
# API 金鑰：所有連線都要帶 Authorization: Bearer <金鑰>
SERVE_API_KEY="$SERVE_API_KEY"

# 下載需要授權的模型時填（https://huggingface.co/settings/tokens）
HF_TOKEN="$HF_TOKEN"

# FP8 模型在 RTX 50 系列（Blackwell）預設會用 DeepGEMM，它要現場編譯、需要完整 CUDA Toolkit；
# 0 = 關閉，改用 vLLM 內建的 FP8 kernel（不必另裝 CUDA Toolkit）
VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM:-0}"
# FlashInfer 取樣同樣需要現場編譯；0 = 改用 PyTorch 取樣
VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"
EOF
)
ok "模型 $SERVE_MODEL → 名稱 $SERVE_NAME，上下文 $SERVE_MAX_LEN，埠 $SERVE_PORT"

# 啟動腳本：每次啟動都重新讀 vllm.env
cat > "$APP_DIR/run-vllm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$DIR/vllm.env"; set +a
[ -n "${HF_TOKEN:-}" ] || unset HF_TOKEN
args=(serve "$SERVE_MODEL"
      --served-model-name "$SERVE_NAME"
      --host "$SERVE_HOST" --port "$SERVE_PORT"
      --api-key "$SERVE_API_KEY"
      --max-model-len "$SERVE_MAX_LEN"
      --gpu-memory-utilization "$SERVE_GPU_UTIL")
if [ -n "${SERVE_TOOL_PARSER:-}" ]; then
    args+=(--enable-auto-tool-choice --tool-call-parser "$SERVE_TOOL_PARSER")
fi
if [ "${SERVE_ATTN_BACKEND:-}" = auto ]; then
    # 規則同 lib.sh 的 auto_attn_backend：沒有 nvcc 時，Blackwell（10 以上，例如 RTX 50）一律 Triton；
    # Hopper 以前（RTX 30/40、A100）用 FP8 KV cache 也用 Triton；H100 / H200 及有 nvcc 時交給 vLLM
    SERVE_ATTN_BACKEND=""
    SMI="$(command -v nvidia-smi || echo /usr/lib/wsl/lib/nvidia-smi)"
    CC_MAJOR="$("$SMI" --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | cut -d. -f1 || true)"
    CC_MAJOR="${CC_MAJOR:-0}"
    if ! command -v nvcc >/dev/null 2>&1 && [ ! -x /usr/local/cuda/bin/nvcc ]; then
        if [ "$CC_MAJOR" -ge 10 ]; then
            SERVE_ATTN_BACKEND=TRITON_ATTN
        elif [ "$CC_MAJOR" -ge 1 ] && [ "$CC_MAJOR" -lt 9 ] && [[ "${SERVE_EXTRA_ARGS:-}" == *"--kv-cache-dtype fp8"* ]]; then
            SERVE_ATTN_BACKEND=TRITON_ATTN
        fi
    fi
fi
if [ -n "${SERVE_ATTN_BACKEND:-}" ]; then
    args+=(--attention-backend "$SERVE_ATTN_BACKEND")
fi
# shellcheck disable=SC2206
args+=(${SERVE_EXTRA_ARGS:-})
echo "vllm ${args[*]//$SERVE_API_KEY/***}"
exec "$DIR/.venv/bin/vllm" "${args[@]}"
EOF
chmod 755 "$APP_DIR/run-vllm.sh"

# --- 4. 預先下載模型 --------------------------------------------------------
step "4. 下載模型權重（存在 ~/.cache/huggingface）"
if [ "$WARMUP" = 1 ]; then
    HF_BIN="$APP_DIR/.venv/bin/hf"
    [ -x "$HF_BIN" ] || HF_BIN="$APP_DIR/.venv/bin/huggingface-cli"
    if HF_TOKEN="${HF_TOKEN:-}" "$HF_BIN" download "$SERVE_MODEL" >/dev/null; then
        ok "$SERVE_MODEL 下載完成"
    else
        warn "下載失敗（需要授權的模型請加 --hf-token），服務啟動時會再試一次"
    fi
else
    warn "略過（--no-warmup）"
fi

# --- 5. systemd 服務 --------------------------------------------------------
step "5. 註冊 systemd 服務 $SERVICE（開機自動啟動）"
sudo tee "/etc/systemd/system/$SERVICE.service" >/dev/null <<EOF
[Unit]
Description=vLLM OpenAI-compatible server
After=network-online.target
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=$APP_DIR
Environment=HF_HOME=$HOME/.cache/huggingface
Environment=PATH=$APP_DIR/.venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$APP_DIR/run-vllm.sh
Restart=on-failure
RestartSec=10
KillMode=mixed
TimeoutStartSec=0
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null
sudo systemctl restart "$SERVICE"
ok "服務已啟動"

# --- 6. 等待模型載入 --------------------------------------------------------
step "6. 等待模型載入（第一次會編譯，約 1~10 分鐘）"
URL="http://127.0.0.1:$SERVE_PORT"
for i in $(seq 1 240); do
    if curl -fsS -m 3 "$URL/health" >/dev/null 2>&1; then
        ok "vLLM 已就緒（${i}x5 秒）"
        break
    fi
    if ! systemctl is-active --quiet "$SERVICE"; then
        journalctl -u "$SERVICE" -n 40 --no-pager || true
        die "vLLM 啟動失敗。往上找第一個 RuntimeError；顯存不足可調小 SERVE_MAX_LEN 或換 --preset small 再重跑"
    fi
    sleep 5
done
curl -fsS -m 3 "$URL/health" >/dev/null 2>&1 || die "等太久仍未就緒，查看： journalctl -u $SERVICE -f"

REPLY="$(curl -fsS -m 120 "$URL/v1/chat/completions" \
    -H "Authorization: Bearer $SERVE_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$SERVE_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi in 5 words.\"}],\"max_tokens\":30}" \
    | jq -r '.choices[0].message.content' 2>/dev/null || true)"
[ -n "$REPLY" ] && ok "測試回應：$REPLY" || warn "測試請求失敗，查看： journalctl -u $SERVICE -n 50"

step "vLLM 完成"
echo "  API：     http://<這台的IP>:$SERVE_PORT/v1   模型名稱：$SERVE_NAME"
echo "  管理：    Windows 雙擊 server\\wsl2\\vllmctl.cmd；Ubuntu：./vllmctl.sh（info = 給同學的連線資訊）"
echo "  紀錄：    journalctl -u $SERVICE -f"
