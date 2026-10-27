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

# nvidia-smi：WSL 的在 /usr/lib/wsl/lib（systemd 服務的 PATH 裡沒有）
smi() {
    local s
    for s in nvidia-smi /usr/lib/wsl/lib/nvidia-smi; do
        command -v "$s" >/dev/null 2>&1 && { "$s" "$@"; return; }
    done
    return 127
}

# 第一張 GPU 的顯存（MiB）；沒有 GPU 回傳 0
gpu_mem_mib() {
    local m; m="$(smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')"
    echo "${m:-0}"
}

# 偵測第一張 GPU → GPU_NAME、GPU_MEM_MIB、GPU_CC（例 9.0）、GPU_ARCH、GPU_COUNT
#   架構看 compute capability：8.0/8.6 Ampere（RTX 30、A100）、8.9 Ada（RTX 40、L40S）、
#   9.0 Hopper（H100、H200）、10.x Blackwell 資料中心（B200）、12.x Blackwell 消費級（RTX 50）
gpu_detect() {
    local line
    line="$(smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader,nounits 2>/dev/null | head -n1)"
    GPU_NAME="$(echo "$line" | cut -d, -f1 | sed 's/^ *//;s/ *$//')"
    GPU_MEM_MIB="$(echo "$line" | cut -d, -f2 | tr -d ' ')"; GPU_MEM_MIB="${GPU_MEM_MIB:-0}"
    GPU_CC="$(echo "$line" | cut -d, -f3 | tr -d ' ')"; GPU_CC="${GPU_CC:-0.0}"
    GPU_COUNT="$(smi -L 2>/dev/null | grep -c '^GPU ' || true)"
    case "${GPU_CC%%.*}" in
        7)  GPU_ARCH="Turing/Volta" ;;
        8)  if [ "$GPU_CC" = "8.9" ]; then GPU_ARCH="Ada"; else GPU_ARCH="Ampere"; fi ;;
        9)  GPU_ARCH="Hopper" ;;
        10|11) GPU_ARCH="Blackwell（資料中心）" ;;
        12) GPU_ARCH="Blackwell（RTX 50）" ;;
        *)  GPU_ARCH="未知" ;;
    esac
}

has_nvcc() { command -v nvcc >/dev/null 2>&1 || [ -x /usr/local/cuda/bin/nvcc ]; }

# 注意力運算後端（SERVE_ATTN_BACKEND=auto 時用；run-vllm.sh 啟動時用同樣的規則）：
#   有 CUDA Toolkit（nvcc）→ 交給 vLLM
#   Blackwell（RTX 50、B200）預設用 FlashInfer，沒有 nvcc 時暖機會現場編譯失敗 → Triton
#   Hopper 以前（RTX 30/40、A100）的 FlashAttention 不支援 FP8 KV cache，vLLM 會改找 FlashInfer → 同樣的風險 → Triton
#   H100 / H200 的 FlashAttention（FA3）支援 FP8 KV cache → 交給 vLLM；強制 Triton 反而慢又不穩（H200 實測卡住）
# $1 = vllm serve 的其他參數（看有沒有 --kv-cache-dtype fp8）
auto_attn_backend() {
    local major="${GPU_CC%%.*}"
    if has_nvcc; then echo ""
    elif [ "${major:-0}" -ge 10 ]; then echo TRITON_ATTN
    elif [ "${major:-0}" -ge 1 ] && [ "${major:-0}" -lt 9 ] && [[ "${1:-}" == *"--kv-cache-dtype fp8"* ]]; then echo TRITON_ATTN
    else echo ""
    fi
}

# 所有組合共用的基本參數：
#   --kv-cache-dtype fp8   對話記憶（KV cache）用 FP8 存，容量約加倍
#   --enforce-eager        不建 CUDA graph：啟動快、省顯存（小顯卡用；大顯卡建 CUDA graph 生成快很多）
BASE_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 6"

# 依顯存挑預設組合
auto_preset() {
    local mib="${GPU_MEM_MIB:-}"; [ -n "$mib" ] || mib="$(gpu_mem_mib)"
    if   [ "${mib:-0}" -ge 100000 ]; then echo xlarge
    elif [ "${mib:-0}" -ge 46000 ]; then echo large
    elif [ "${mib:-0}" -ge 15500 ]; then echo medium
    elif [ "${mib:-0}" -ge 11000 ]; then echo laptop
    else echo small
    fi
}

# 依架構調整組合參數：RTX 30 / A100（Ampere 以前）沒有 FP8 硬體，KV cache 改回預設格式
gpu_tune_extra() {
    local extra="$1" major="${GPU_CC%%.*}"
    if [ -n "${GPU_CC:-}" ] && [ "$GPU_CC" != "0.0" ] && { [ "$major" -lt 8 ] || { [ "$major" = 8 ] && [ "$GPU_CC" != "8.9" ]; }; }; then
        extra="$(echo "$extra" | sed 's/--kv-cache-dtype fp8 *//')"
    fi
    echo "$extra"
}

# 模型組合 → 設定 PRESET_* 變數
#   opencode 每次請求都帶約 1 萬 token 的系統提示與工具定義，所以上下文比模型大小重要，
#   而且模型一定要支援 tool calling。
apply_preset() {
    PRESET_GPU_UTIL=0.90
    PRESET_TOOL_PARSER=hermes
    case "$1" in
        small)    # 8~10GB（例：RTX 4060 / 4070 Laptop 8GB）
            PRESET_MODEL="Qwen/Qwen3-4B-Instruct-2507-FP8"; PRESET_NAME="qwen3-4b"
            PRESET_MAX_LEN=16384
            PRESET_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 4"
            ;;
        laptop)   # 11~15GB（例：RTX 5070 Ti Laptop 12GB、RTX 4070 桌機 12GB）——實驗室筆電實測的建議設定
            PRESET_MODEL="Qwen/Qwen3-4B-Instruct-2507-FP8"; PRESET_NAME="qwen3-4b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="$BASE_EXTRA"
            ;;
        quality)  # 11~15GB 的替代選擇：8B，實測較慢、可同時服務的人較少，寫程式沒有比較好
            PRESET_MODEL="Qwen/Qwen3-8B-AWQ"; PRESET_NAME="qwen3-8b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="--kv-cache-dtype fp8 --enforce-eager --max-num-seqs 4 --reasoning-parser qwen3 --default-chat-template-kwargs {\"enable_thinking\":false}"
            ;;
        medium)   # 16~45GB（例：H100-20C vGPU 20GB、RTX 4090 24GB、RTX 5090 32GB）——尚未實測
            # 不加 --enforce-eager：權重約 10GB，顯存夠建 CUDA graph，生成速度快很多
            PRESET_MODEL="Qwen/Qwen3-14B-AWQ"; PRESET_NAME="qwen3-14b"
            PRESET_MAX_LEN=32768
            PRESET_EXTRA="--kv-cache-dtype fp8 --max-num-seqs 8 --reasoning-parser qwen3 --default-chat-template-kwargs {\"enable_thinking\":false}"
            ;;
        large)    # 46~99GB（例：H100 80GB、A100 80GB、L40S 48GB）——尚未實測
            PRESET_MODEL="Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"; PRESET_NAME="qwen3-coder-30b"
            PRESET_MAX_LEN=65536; PRESET_TOOL_PARSER=qwen3_coder
            PRESET_EXTRA="--max-num-seqs 16"
            ;;
        xlarge)   # 100GB 以上（例：H200 141GB、B200）：同一個模型，上下文加倍、可同時服務更多人
            PRESET_MODEL="Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"; PRESET_NAME="qwen3-coder-30b"
            PRESET_MAX_LEN=131072; PRESET_TOOL_PARSER=qwen3_coder
            PRESET_EXTRA="--max-num-seqs 32"
            ;;
        *) die "未知的組合：$1（可用 small / laptop / quality / medium / large / xlarge；vllmctl presets 看說明）" ;;
    esac
    PRESET_EXTRA="$(gpu_tune_extra "$PRESET_EXTRA")"
}

list_presets() {
    cat <<'EOF'
組合      顯存       模型                                  上下文  說明
small     8~10GB     Qwen3-4B-Instruct-2507-FP8            16k     8GB 筆電
laptop    11~15GB    Qwen3-4B-Instruct-2507-FP8            32k     ★ 實驗室筆電（RTX 5070 Ti 12GB）實測建議
quality   11~15GB    Qwen3-8B-AWQ（不思考模式）            32k     實測：較慢、同時人數較少、寫程式沒比較好
medium    16~45GB    Qwen3-14B-AWQ（不思考模式）           32k     H100-20C vGPU、RTX 4090/5090；未實測
large     46~99GB    Qwen3-Coder-30B-A3B-Instruct-FP8      64k     H100 80GB、A100 80GB、L40S；未實測
xlarge    100GB+     Qwen3-Coder-30B-A3B-Instruct-FP8      128k    H200 141GB、B200；同時 32 人；未實測
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

# 筆電的 mDNS 名稱（例 CYH.local）：實驗室 DHCP 換 IP 也不用改 client 設定；不在 WSL（例 Ubuntu 伺服器）就回空字串
# 用 .local（mDNS）而不用裸主機名稱：實驗室 Wi-Fi 常被設成「公用」網路，LLMNR/NetBIOS 會被防火牆擋，mDNS 不會
lan_host() {
    grep -qi microsoft /proc/version 2>/dev/null || return 0
    local h; h="$(cmd.exe /c hostname 2>/dev/null | tr -d '\r\n')"
    echo "${h:-$(hostname)}.local"
}
