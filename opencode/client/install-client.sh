#!/usr/bin/env bash
# =============================================================================
#  install-client.sh — Ubuntu 電腦（例如伺服器主機）安裝 opencode，並連到實驗室筆電的 vLLM
#  （Windows 電腦請改用同資料夾的 install-client.cmd）
#
#  用法（網址與金鑰在筆電雙擊 host\vllmctl.cmd 輸入 info 可看到）：
#      bash install-client.sh --url http://192.168.1.23:8000/v1 --key sk-vllm-xxx --name laptop
#
#  參數：
#      --url URL     vLLM 的 OpenAI 相容網址（要含 /v1）
#      --key KEY     vLLM 的 API 金鑰
#      --name ID     provider 名稱（預設 vllm；連多台時用不同名字，例 laptop / server）
#      --default     設成 opencode 的預設模型（第一個加入的 provider 也會自動設成預設）
#      --models A,B  只加入這些模型，逗號分隔（伺服器模型很多時用，例如國網 API）
#      --context N   伺服器沒回報上下文長度時使用的值（預設 16384）
#      --label TEXT  opencode 裡顯示的 provider 名稱（預設「vLLM (name)」）
#
#  可重複執行：會「合併」進 ~/.config/opencode/opencode.json，不會刪掉其他 provider。
#  金鑰另存在 ~/.config/opencode/keys/<name>.key（權限 600），設定檔裡不放明碼。
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() { printf '\n\033[36m==== %s ====\033[0m\n' "$1"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m[!]\033[0m  %s\n' "$1"; }
die()  { printf '  \033[31m[X]\033[0m  %s\n' "$1" >&2; exit 1; }

URL="" KEY="" PNAME="vllm" MAKE_DEFAULT=0 ONLY="" CTX=16384 LABEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url)     URL="${2%/}"; shift 2 ;;
        --key)     KEY="$2"; shift 2 ;;
        --name)    PNAME="$2"; shift 2 ;;
        --default) MAKE_DEFAULT=1; shift ;;
        --models)  ONLY="$2"; shift 2 ;;
        --context) CTX="$2"; shift 2 ;;
        --label)   LABEL="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "不認得的參數：$1" ;;
    esac
done
[[ "$PNAME" =~ ^[a-zA-Z0-9_-]+$ ]] || die "--name 只能用英數字、- 和 _"

[ -n "$URL" ] || die "請用 --url 提供筆電的 vLLM 網址（在筆電雙擊 host\\vllmctl.cmd 輸入 info 可看到）"
[ -n "$KEY" ] || die "請用 --key 提供 API 金鑰（在筆電雙擊 host\\vllmctl.cmd 輸入 info 可看到）"
case "$URL" in */v1) ;; *) URL="$URL/v1" ;; esac

# --- 1. 套件 ----------------------------------------------------------------
step "1. 必要套件"
need=()
for c in curl jq python3; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [ ${#need[@]} -gt 0 ]; then sudo apt-get update -y && sudo apt-get install -y "${need[@]}"; fi
ok "完成"

# --- 2. 測試連線並取得模型清單 ----------------------------------------------
step "2. 連線測試 $URL"
MODELS_JSON="$(curl -fsS -m 10 -H "Authorization: Bearer $KEY" "$URL/models")" \
    || die "連不到 $URL/models（服務沒開？IP 變了？不在同一個網路？防火牆？金鑰錯？）"
if [ -n "$ONLY" ]; then
    # 依 --models 的順序排，第一個就是預設模型
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg only "$ONLY" '($only | split(",") | map(ltrimstr(" ") | rtrimstr(" "))) as $w
        | .data |= [$w[] as $id | .[] | select(.id == $id)]')"
    [ "$(echo "$MODELS_JSON" | jq '.data | length')" -gt 0 ] || die "--models 指定的模型伺服器上都沒有"
fi
echo "$MODELS_JSON" | jq -r --arg ctx "$CTX" '.data[] | "  - \(.id)  (context \(.max_model_len // "未回報，用 \($ctx)"))"'
ok "連線成功"

# --- 3. 安裝 opencode -------------------------------------------------------
step "3. 安裝 / 更新 opencode"
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
if command -v opencode >/dev/null 2>&1; then
    opencode upgrade >/dev/null 2>&1 || true
else
    # 官方安裝腳本（https://github.com/anomalyco/opencode）；固定裝到 ~/.opencode/bin，PATH 才好設定
    curl -fsSL https://opencode.ai/install | OPENCODE_INSTALL_DIR="$HOME/.opencode/bin" bash
fi
command -v opencode >/dev/null 2>&1 || die "opencode 安裝失敗"
ok "opencode $(opencode --version 2>/dev/null || true)  →  $(command -v opencode)"
# 確保新開的終端機找得到 opencode
if ! grep -q '.opencode/bin' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.opencode/bin:$PATH"' >> "$HOME/.bashrc"
fi

# --- 4. 寫入設定 ------------------------------------------------------------
step "4. 寫入 ~/.config/opencode/opencode.json（provider：$PNAME）"
CFG_DIR="$HOME/.config/opencode"
mkdir -p "$CFG_DIR/keys"
( umask 077; printf '%s' "$KEY" > "$CFG_DIR/keys/$PNAME.key" )
[ ! -f "$CFG_DIR/opencode.json" ] || cp "$CFG_DIR/opencode.json" "$CFG_DIR/opencode.json.bak"

DEFAULT_MODEL="$(MODELS_JSON="$MODELS_JSON" CTX="$CTX" LABEL="$LABEL" python3 - "$CFG_DIR/opencode.json" "$PNAME" "$URL" "$MAKE_DEFAULT" <<'PY'
import json, os, sys
path, pname, url, make_default = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
cfg.setdefault("$schema", "https://opencode.ai/config.json")

models = {}
for m in json.loads(os.environ["MODELS_JSON"])["data"]:
    ctx = int(m.get("max_model_len") or os.environ["CTX"])
    models[m["id"]] = {
        "name": f'{m["id"]} ({pname})',
        "tool_call": True,
        # 輸出上限留在上下文的 1/4 以內，剩下給 opencode 的 prompt 和程式碼
        "limit": {"context": ctx, "output": min(8192, ctx // 4)},
    }

cfg.setdefault("provider", {})[pname] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": os.environ["LABEL"] or f"vLLM ({pname})",
    "options": {"baseURL": url, "apiKey": "{file:~/.config/opencode/keys/%s.key}" % pname},
    "models": models,
}
first = f"{pname}/{next(iter(models))}"
# 預設模型若指向這個 provider、但模型已不存在（筆電用 vllmctl 換過模型），自動改成新模型
stale = any(
    str(cfg.get(k, "")).startswith(pname + "/") and str(cfg[k])[len(pname) + 1:] not in models
    for k in ("model", "small_model")
)
if make_default or stale or "model" not in cfg:
    cfg["model"] = first
    cfg["small_model"] = first   # 產生標題 / 摘要也用自架模型，不連外
with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
print(cfg["model"])
PY
)"
ok "預設模型：$DEFAULT_MODEL"

# --- 5. 全域規則檔 ----------------------------------------------------------
step "5. 安裝全域規則（$CFG_DIR/AGENTS.md）"
RULES_SRC="$HERE/opencode-rules.md"
RULES_DST="$CFG_DIR/AGENTS.md"
if [ ! -f "$RULES_SRC" ]; then
    warn "找不到 opencode-rules.md，略過"
elif [ -f "$RULES_DST" ] && ! grep -q "lab-opencode-rules" "$RULES_DST"; then
    warn "已經有自己的 AGENTS.md，不覆蓋（要改用實驗室版本請先刪除或改名它）"
else
    tr -d '\r' < "$RULES_SRC" > "$RULES_DST"
    ok "已安裝：回答用繁體中文、相對路徑、查資料附來源與日期、不捏造文獻"
fi

step "opencode 完成"
echo "  開新終端機（或 source ~/.bashrc），到專案資料夾執行： opencode"
echo "  在 opencode 裡輸入 /models 可切換 provider / 模型"
echo "  設定檔：$CFG_DIR/opencode.json（舊版備份在 opencode.json.bak）"
