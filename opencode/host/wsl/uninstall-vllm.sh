#!/usr/bin/env bash
# =============================================================================
#  uninstall-vllm.sh — 移除 WSL / Ubuntu 裡由本專案安裝的 vLLM（由 host\uninstall-host.cmd 呼叫）
#
#    bash uninstall-vllm.sh [--keep-models]
#
#  會移除：
#    • systemd 服務 vllm（以及舊版 Discord bot 專案的 llama-swap）
#    • ~/vllm-server（vLLM 環境、vllm.env 設定與金鑰）、~/vllm-opencode-setup、~/bench-results
#    • 舊版 llama-swap 的 ~/llm（確認裡面是 llama-swap 才刪）
#    • 本專案下載的模型（~/.cache/huggingface 裡的內建組合模型與目前使用的模型）
#  不會動：Ubuntu 本身、apt 套件、uv、你自己下載的其他模型、其他資料夾
# =============================================================================
set -uo pipefail
KEEP_MODELS=0
[ "${1:-}" = "--keep-models" ] && KEEP_MODELS=1

step() { printf '\n\033[36m==== %s ====\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m  %s\n' "$1"; }

APP_DIR="$HOME/vllm-server"
HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# 先記下目前使用的模型（設定檔等一下會被刪掉）
CURRENT_MODEL=""
if [ -f "$APP_DIR/vllm.env" ]; then
    CURRENT_MODEL="$(. "$APP_DIR/vllm.env" 2>/dev/null; printf %s "${SERVE_MODEL:-}")"
fi

step "1. 停止並移除 systemd 服務（會詢問 Ubuntu 密碼）"
for svc in vllm llama-swap; do
    if [ -f "/etc/systemd/system/$svc.service" ]; then
        sudo systemctl disable --now "$svc" >/dev/null 2>&1 || true
        sudo rm -f "/etc/systemd/system/$svc.service"
        ok "已移除服務 $svc"
    fi
done
sudo systemctl daemon-reload 2>/dev/null || true

step "2. 刪除安裝資料夾"
for d in "$APP_DIR" "$HOME/vllm-opencode-setup" "$HOME/bench-results"; do
    if [ -e "$d" ]; then rm -rf "$d"; ok "已刪除 $d"; fi
done
# 舊版 Discord bot 專案自己架的 llama-swap：只刪它放的檔案，資料夾空了才刪
if [ -x "$HOME/llm/llama-swap" ] && [ -f "$HOME/llm/llama-swap.yaml" ]; then
    rm -rf "$HOME/llm/.venv" "$HOME/llm/llama-swap" "$HOME/llm/llama-swap.yaml" \
           "$HOME/llm/llama-swap.yaml.bak" "$HOME/llm/llama-swap.env"
    rmdir "$HOME/llm" 2>/dev/null && ok "已刪除舊版 llama-swap（~/llm）" || ok "已刪除舊版 llama-swap 的檔案（~/llm 裡還有其他東西，保留資料夾）"
fi

step "3. 刪除本專案下載的模型"
if [ "$KEEP_MODELS" = 1 ]; then
    warn "略過（--keep-models），模型留在 $HUB"
else
    MODELS="Qwen/Qwen3-4B-Instruct-2507-FP8 Qwen/Qwen3-8B-AWQ Qwen/Qwen3-14B-AWQ \
            Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 Qwen/Qwen2.5-7B-Instruct-AWQ $CURRENT_MODEL"
    freed=0
    for m in $MODELS; do
        dir="$HUB/models--${m//\//--}"
        if [ -d "$dir" ]; then
            size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
            rm -rf "$dir"
            ok "已刪除 $m（$size）"
            freed=1
        fi
    done
    [ "$freed" = 1 ] || ok "沒有找到本專案下載的模型"
    other="$(ls -d "$HUB"/models--* 2>/dev/null | wc -l)"
    [ "$other" -gt 0 ] && warn "$HUB 裡還有 $other 個其他模型（不是本專案下載的，保留）"
fi

step "WSL 端清除完成"
echo "  保留：Ubuntu 本身、apt 套件、uv（~/.local/bin/uv）。要整個移除 Ubuntu 請用 uninstall-host -RemoveWsl"
