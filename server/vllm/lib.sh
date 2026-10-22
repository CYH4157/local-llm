# shellcheck shell=bash
# =============================================================================
#  lib.sh — server/vllm 底下各腳本共用的函式與模型組合（被 source，不直接執行）
# =============================================================================

APP_DIR="${APP_DIR:-$HOME/vllm-server}"     # vLLM 安裝位置（venv、設定、啟動腳本）
ENV_FILE="$APP_DIR/vllm.env"                # 模型 / 埠號 / 金鑰設定
PROFILE_DIR="$APP_DIR/models"               # 用過的模型各自的設定（vllmctl switch 切換用）
SERVICE=vllm                                # systemd 服務名稱
# 跟著模型走的設定；埠號、金鑰等其他設定切換模型時不變
PROFILE_KEYS="SERVE_MODEL|SERVE_NAME|SERVE_MAX_LEN|SERVE_GPU_UTIL|SERVE_TOOL_PARSER|SERVE_EXTRA_ARGS"

step() { printf '\n\033[36m==== %s ====\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m  %s\n' "$1"; }
die()  { printf '  \033[31m[X]\033[0m  %s\n' "$1" >&2; exit 1; }

# 讀取 vllm.env（變數以 SERVE_ 開頭，刻意避開 vLLM 自己會讀的 VLLM_PORT 等環境變數）
load_env() {
    [ -f "$ENV_FILE" ] || die "找不到 $ENV_FILE，請先執行 setup-vllm.sh"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
}

# 第一張 GPU 的顯存（MiB）；沒有 GPU 回傳 0
gpu_mem_mib() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' '
    else
        echo 0
    fi
}

# 所有組合共用的基本參數：
#   --kv-cache-dtype fp8   對話記憶（KV cache）用 FP8 存，容量約加倍
#   --enforce-eager        不建 CUDA graph：啟動快、省顯存
BASE_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 6"

# 依顯存挑預設組合
auto_preset() {
    local mib; mib="$(gpu_mem_mib)"
    if   [ "${mib:-0}" -ge 46000 ]; then echo large
    elif [ "${mib:-0}" -ge 15500 ]; then echo medium
    elif [ "${mib:-0}" -ge 11000 ]; then echo laptop
    else echo small
    fi
}

# 模型組合 → 設定 PRESET_* 變數
#   opencode 每次請求都帶約 1 萬 token 的系統提示與工具定義，所以上下文比模型大小重要，
#   而且模型一定要支援 tool calling。
apply_preset() {
    PRESET_GPU_UTIL=0.90
    PRESET_TOOL_PARSER=hermes
    case "$1" in
        small)    # 8~10GB（例：RTX 4060/4070 Laptop 8GB）
            PRESET_MODEL="Qwen/Qwen3-4B-Instruct-2507-FP8"; PRESET_NAME="qwen3-4b"
            PRESET_MAX_LEN=16384
            PRESET_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 4"
            ;;
        laptop)   # 11~15GB（例：RTX 5070 Ti Laptop 12GB）——實驗室筆電實測的建議設定
            PRESET_MODEL="Qwen/Qwen3-4B-Instruct-2507-FP8"; PRESET_NAME="qwen3-4b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="$BASE_EXTRA"
            ;;
        quality)  # 11~15GB 的替代選擇：8B，實測較慢、可同時服務的人較少，寫程式沒有比較好
            PRESET_MODEL="Qwen/Qwen3-8B-AWQ"; PRESET_NAME="qwen3-8b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 4 --reasoning-parser qwen3 --default-chat-template-kwargs {\"enable_thinking\":false}"
            ;;
        medium)   # 16~24GB（例：RTX 4090 / 5090 Laptop）——尚未實測
            PRESET_MODEL="Qwen/Qwen3-14B-AWQ"; PRESET_NAME="qwen3-14b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 6 --reasoning-parser qwen3 --default-chat-template-kwargs {\"enable_thinking\":false}"
            ;;
        large)    # 48GB 以上（工作站顯卡）——尚未實測
            PRESET_MODEL="Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"; PRESET_NAME="qwen3-coder-30b"
            PRESET_MAX_LEN=65536; PRESET_TOOL_PARSER=qwen3_coder
            PRESET_EXTRA="--max-num-seqs 16"
            ;;
        *) die "未知的組合：$1（可用 small / laptop / quality / medium / large；vllmctl presets 看說明）" ;;
    esac
}

list_presets() {
    cat <<'EOF'
組合      顯存       模型                                  上下文  說明
small     8~10GB     Qwen3-4B-Instruct-2507-FP8            16k     8GB 筆電
laptop    11~15GB    Qwen3-4B-Instruct-2507-FP8            32k     ★ 實驗室筆電（RTX 5070 Ti 12GB）實測建議
quality   11~15GB    Qwen3-8B-AWQ（不思考模式）            32k     實測：較慢、同時人數較少、寫程式沒比較好
medium    16~24GB    Qwen3-14B-AWQ（不思考模式）           32k     未實測
large     48GB+      Qwen3-Coder-30B-A3B-Instruct-FP8      64k     未實測
EOF
}

# 先下載模型權重（服務不中斷），已下載過會直接略過
hf_download() {
    local hf="$APP_DIR/.venv/bin/hf"
    [ -x "$hf" ] || hf="$APP_DIR/.venv/bin/huggingface-cli"
    echo "  下載 $1（已下載過會直接略過）…"
    HF_TOKEN="${HF_TOKEN:-}" "$hf" download "$1" >/dev/null || die "下載失敗：模型 ID 對嗎？需要授權的模型請先 vllmctl set HF_TOKEN hf_xxx"
    ok "模型已就緒"
}

# 產生隨機 API 金鑰
gen_key() { echo "sk-vllm-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# 這台機器的區網 IP（WSL mirrored 模式下就是筆電的 IP）
lan_ip() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -vE '^(127\.|172\.17\.|169\.254\.)' | grep -E '^[0-9]+\.' | head -n1 || true; }
