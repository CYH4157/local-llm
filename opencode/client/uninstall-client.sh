#!/usr/bin/env bash
# =============================================================================
#  uninstall-client.sh — 移除 install-client.sh 裝的東西（Ubuntu）
#
#    bash uninstall-client.sh [--name laptop] [--keep-program]
#
#  會移除：opencode 設定裡的 provider（預設 laptop）與它的金鑰檔、實驗室共用規則 AGENTS.md、
#          ~/.opencode（opencode 程式）與 ~/.bashrc 裡加入的 PATH
#  不會動：你自己加的其他 provider / 設定、apt 套件
# =============================================================================
set -euo pipefail
PNAME="laptop"; KEEP_PROGRAM=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name) PNAME="$2"; shift 2 ;;
        --keep-program) KEEP_PROGRAM=1; shift ;;
        *) sed -n '2,10p' "$0"; exit 1 ;;
    esac
done
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m  %s\n' "$1"; }

CFG_DIR="$HOME/.config/opencode"
CFG="$CFG_DIR/opencode.json"

if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.uninstall-bak"
    python3 - "$CFG" "$PNAME" <<'PY'
import json, os, sys
path, pname = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
cfg.get("provider", {}).pop(pname, None)
if not cfg.get("provider"):
    cfg.pop("provider", None)
for k in ("model", "small_model"):
    if str(cfg.get(k, "")).startswith(pname + "/"):
        cfg.pop(k)
if set(cfg) <= {"$schema"}:
    os.remove(path)
    print("  設定檔已沒有其他內容，整個刪除")
else:
    json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
    print("  已移除 provider，其他設定保留")
PY
    ok "opencode 設定已處理（備份：$CFG.uninstall-bak）"
fi
rm -f "$CFG_DIR/keys/$PNAME.key" "$CFG.bak"
rmdir "$CFG_DIR/keys" 2>/dev/null || true

if [ -f "$CFG_DIR/AGENTS.md" ] && grep -q "lab-opencode-rules" "$CFG_DIR/AGENTS.md"; then
    rm -f "$CFG_DIR/AGENTS.md"; ok "已刪除實驗室共用規則 AGENTS.md"
fi

if [ "$KEEP_PROGRAM" = 0 ]; then
    if [ -d "$HOME/.opencode" ]; then rm -rf "$HOME/.opencode"; ok "已刪除 ~/.opencode（opencode 程式）"; fi
    if [ -f "$HOME/.bashrc" ] && grep -qxF 'export PATH="$HOME/.opencode/bin:$PATH"' "$HOME/.bashrc"; then
        grep -vxF 'export PATH="$HOME/.opencode/bin:$PATH"' "$HOME/.bashrc" > "$HOME/.bashrc.tmp" && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
        ok "已從 ~/.bashrc 移除 opencode 的 PATH"
    fi
else
    warn "保留 opencode 程式（--keep-program）"
fi
ok "完成"
