#!/usr/bin/env bash
# =============================================================================
#  uninstall-vllm.sh — 移除 WSL / Ubuntu 裡由本專案安裝的 vLLM（由 server\wsl2\uninstall-host.cmd 呼叫）
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

# 模型要在刪掉 ~/vllm-server 之前處理：用 venv 裡的 hf 工具刪，才能正確釋放空間
# （新版 Hugging Face 快取把權重放在共用的 hub/blobs，只刪 models--* 資料夾空間不會釋放）
step "2. 刪除本專案下載的模型"
if [ "$KEEP_MODELS" = 1 ]; then
    warn "略過（--keep-models），模型留在 $HUB"
else
    # 內建組合 + 目前的模型 + vllmctl 記錄過的模型（~/vllm-server/models/*.env）
    MODELS="Qwen/Qwen3-4B-Instruct-2507-FP8 Qwen/Qwen3-8B-AWQ Qwen/Qwen3-14B-AWQ \
            Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 Qwen/Qwen2.5-7B-Instruct-AWQ $CURRENT_MODEL"
    for p in "$APP_DIR"/models/*.env; do
        [ -f "$p" ] && MODELS="$MODELS $(. "$p" 2>/dev/null; printf %s "${SERVE_MODEL:-}")"
    done
    MODELS="$(printf '%s\n' $MODELS | sort -u)"
    HF="$APP_DIR/.venv/bin/hf"
    [ -x "$HF" ] || HF="$(command -v hf || true)"
    export HF_HUB_DISABLE_UPDATE_CHECK=1
    freed=0
    if [ -n "$HF" ]; then
        cached="$("$HF" cache ls -q 2>/dev/null)"
        for m in $MODELS; do
            if printf '%s\n' "$cached" | grep -qx "model/$m"; then
                "$HF" cache rm -y "model/$m" >/dev/null 2>&1 && { ok "已刪除 $m"; freed=1; } || warn "刪除 $m 失敗"
            fi
        done
        left="$("$HF" cache ls -q 2>/dev/null | grep -c '^model/' || true)"
    else
        # 沒有 hf 工具時退回直接刪資料夾（舊版快取格式可以釋放空間；新版格式的權重可能留在 hub/blobs）
        for m in $MODELS; do
            dir="$HUB/models--${m//\//--}"
            if [ -d "$dir" ]; then rm -rf "$dir"; ok "已刪除 $m"; freed=1; fi
        done
        left="$(ls -d "$HUB"/models--* 2>/dev/null | wc -l)"
        warn "找不到 hf 工具：如果 $HUB/blobs 仍很大，請手動檢查"
    fi
    [ "$freed" = 1 ] || ok "沒有找到本專案下載的模型"
    [ "${left:-0}" -gt 0 ] && warn "快取裡還有 $left 個其他模型（不是本專案下載的，保留）"
fi

step "3. 刪除安裝資料夾"
for d in "$APP_DIR" "$HOME/vllm-opencode-setup" "$HOME/bench-results"; do
    if [ -e "$d" ]; then rm -rf "$d"; ok "已刪除 $d"; fi
done
# 舊版 Discord bot 專案自己架的 llama-swap：只刪它放的檔案，資料夾空了才刪
if [ -x "$HOME/llm/llama-swap" ] && [ -f "$HOME/llm/llama-swap.yaml" ]; then
    rm -rf "$HOME/llm/.venv" "$HOME/llm/llama-swap" "$HOME/llm/llama-swap.yaml" \
           "$HOME/llm/llama-swap.yaml.bak" "$HOME/llm/llama-swap.env"
    rmdir "$HOME/llm" 2>/dev/null && ok "已刪除舊版 llama-swap（~/llm）" || ok "已刪除舊版 llama-swap 的檔案（~/llm 裡還有其他東西，保留資料夾）"
fi

step "WSL 端清除完成"
echo "  保留：Ubuntu 本身、apt 套件、uv（~/.local/bin/uv）。要整個移除 Ubuntu 請用 uninstall-host -RemoveWsl"
