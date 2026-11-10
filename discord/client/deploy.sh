#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — Ubuntu 伺服器（例如 H200）部署 Discord bot，跟 vLLM 跑在同一台
#  （Windows 筆電請改用同資料夾的 deploy.ps1）
#
#  兩種模型來源（擇一）：
#    A.【本地 vLLM】bot 跟 vLLM 跑在同一台（預設）。前提：已用 server/vllm/setup-vllm.sh
#       架好 vLLM（~/vllm-server/vllm.env），金鑰自動讀該檔，.env 不放金鑰。
#    B.【遠端 gateway】接外部 OpenAI 相容服務（例如 NCHC genai）。用 --remote 指定網址、
#       --api-key 指定金鑰，不需要本機 vLLM。
#  做的事：
#      1. 確認模型服務正常（本地 vLLM 或遠端 gateway）
#      2. 建立 bot 的 Python 環境（.venv）
#      3. 產生 / 更新 .env
#      4. 註冊 systemd 服務 discord-bot：開機自動啟動、掛掉 10 秒後自動重啟
#
#  用法：
#    【本地 vLLM】
#      bash deploy.sh --token <TOKEN>     直接填 Discord token 並啟動
#      bash deploy.sh                     先裝好，之後把 token 填進 .env 再 restart
#    【遠端 gateway】
#      bash deploy.sh --remote <URL> --api-key <KEY> --token <TOKEN>
#          例：--remote https://inner-medusa.genai.nchc.org.tw/v1 --api-key sk-xxxx
#      bash deploy.sh --remote <URL> --api-key <KEY> --model <模型名> --token <TOKEN>
#          gateway 掛多個模型時，用 --model 指定要用哪個（不指定=清單第一個）
#    【共用】
#      --channel <ID>  只在這個頻道自動回一般聊天（其他頻道要 @bot/私訊；留空=每個頻道都回，較吵）
#      --no-service    不註冊 systemd 服務（手動執行：.venv/bin/python discord_bot.py）
#      --uninstall     停止並移除服務（.env 與 .venv 保留）
#      （Discord token：Developer Portal → Bot → Reset Token；不是 LLM 的 sk- 金鑰）
#
#  日常管理：
#      sudo systemctl status discord-bot     狀態
#      journalctl -u discord-bot -f          即時紀錄（看到「[已上線]」就是好了）
#      sudo systemctl restart discord-bot    改完 .env 後重啟
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../../server/vllm/lib.sh
. "$REPO/server/vllm/lib.sh"
BOT_SERVICE=discord-bot
UNIT="/etc/systemd/system/$BOT_SERVICE.service"

TOKEN="" SERVICE_ON=1 UNINSTALL=0 REMOTE_URL="" REMOTE_KEY="" REMOTE_MODEL="" CHANNEL_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --token)      TOKEN="$2"; shift 2 ;;
        --remote)     REMOTE_URL="$2"; shift 2 ;;
        --api-key)    REMOTE_KEY="$2"; shift 2 ;;
        --model)      REMOTE_MODEL="$2"; shift 2 ;;
        --channel)    CHANNEL_ID="$2"; shift 2 ;;
        --no-service) SERVICE_ON=0; shift ;;
        --uninstall)  UNINSTALL=1; shift ;;
        -h|--help)    awk 'NR>1 && /^set -euo/{exit} NR>1' "$0"; exit 0 ;;
        *) die "不認得的參數：$1（看說明：bash $0 --help）" ;;
    esac
done
[ "$(id -u)" -ne 0 ] || die "請用一般使用者執行（跟 vLLM 同一個帳號；需要時腳本會自己呼叫 sudo）"

if [ "$UNINSTALL" = 1 ]; then
    step "移除 systemd 服務 $BOT_SERVICE"
    sudo systemctl disable --now "$BOT_SERVICE" 2>/dev/null || true
    sudo rm -f "$UNIT"
    sudo systemctl daemon-reload
    ok "已移除服務；$HERE/.env 與 .venv 保留（不需要可自行刪除）"
    exit 0
fi

# --- 1. 確認模型服務 ----------------------------------------------------------
if [ -n "$REMOTE_URL" ]; then
    step "1. 檢查遠端模型服務（OpenAI 相容 gateway）"
    BASE_URL="${REMOTE_URL%/}"; case "$BASE_URL" in */v1) ;; *) BASE_URL="$BASE_URL/v1" ;; esac
    if [ -z "$REMOTE_KEY" ]; then
        warn "沒給 --api-key：跳過連線測試。記得之後把金鑰填進 .env 的 LLM_API_KEY 再 restart"
    elif MODELS="$(curl -fsS -m 10 -H "Authorization: Bearer $REMOTE_KEY" "$BASE_URL/models" 2>/dev/null)"; then
        ok "遠端服務正常：$(echo "$MODELS" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("、".join(m["id"] for m in d[:5]) + ("…" if len(d)>5 else ""))')  $BASE_URL"
        [ -n "$REMOTE_MODEL" ] || warn "未指定 --model：bot 會用清單第一個模型；要指定請加 --model <模型名>（或之後改 .env 的 LLM_MODEL）"
    else
        warn "遠端服務連不上或金鑰有誤（$BASE_URL）：設定照樣完成，bot 啟動後會自動重試"
    fi
else
    step "1. 檢查同一台的 vLLM"
    load_env    # 讀 ~/vllm-server/vllm.env（找不到會提示先跑 setup-vllm.sh）
    BASE_URL="http://127.0.0.1:${SERVE_PORT:-8000}/v1"
    if MODELS="$(curl -fsS -m 10 -H "Authorization: Bearer $SERVE_API_KEY" "$BASE_URL/models" 2>/dev/null)"; then
        ok "vLLM 正常：$(echo "$MODELS" | python3 -c 'import json,sys; m=json.load(sys.stdin)["data"][0]; print(m["id"], "（上下文", m.get("max_model_len"), "）")')  $BASE_URL"
    else
        warn "vLLM 目前沒有回應：設定照樣完成，bot 啟動後會自動重試（檢查：bash $REPO/server/vllm/vllmctl.sh status）"
    fi
fi

# --- 2. Python 環境 ------------------------------------------------------------
step "2. 建立 Discord bot 的 Python 環境"
export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
# 沒有 Linux 版的 python（例如整個資料夾從 Windows 複製過來，裡面是 Windows 的 .venv）→ 清掉重建
[ -x "$HERE/.venv/bin/python" ] || uv venv --clear --python 3.12 "$HERE/.venv"
uv pip install --python "$HERE/.venv/bin/python" -r "$HERE/requirements.txt"
ok "套件安裝完成"

# --- 3. .env ------------------------------------------------------------------
step "3. 設定檔 .env"
ENV_BOT="$HERE/.env"
# KEY=VALUE 寫進 .env：有就取代，沒有就加在最後（值裡的 | 和 & 要跳脫，sed 才不會誤解）
set_bot_env() {
    local k="$1" v; v="$(printf '%s' "$2" | sed 's/[|&\\]/\\&/g')"
    if grep -q "^$k=" "$ENV_BOT"; then sed -i "s|^$k=.*|$k=$v|" "$ENV_BOT"; else printf '%s=%s\n' "$1" "$2" >> "$ENV_BOT"; fi
}
if [ ! -f "$ENV_BOT" ]; then
    tr -d '\r' < "$HERE/.env.example" > "$ENV_BOT"
    ok "已建立 .env"
else
    # 舊版 .env 升級：補上新設定，已有的不動
    added=""
    while IFS= read -r line; do
        k="${line%%=*}"
        [[ "$line" =~ ^[A-Z_]+= ]] || continue
        grep -q "^$k=" "$ENV_BOT" || { printf '%s\n' "$line" >> "$ENV_BOT"; added="$added $k"; }
    done < <(tr -d '\r' < "$HERE/.env.example")
    [ -z "$added" ] || ok ".env 已補上：$added"
fi
chmod 600 "$ENV_BOT"    # 裡面有 Discord token
set_bot_env LLM_BASE_URL "$BASE_URL"
if [ -n "$REMOTE_URL" ]; then
    [ -z "$REMOTE_KEY" ] || set_bot_env LLM_API_KEY "$REMOTE_KEY"
    set_bot_env LLM_MODEL "$REMOTE_MODEL"
    ok "遠端模式：LLM_BASE_URL=$BASE_URL、LLM_MODEL=${REMOTE_MODEL:-（自動選第一個）}"
    [ -n "$REMOTE_KEY" ] || warn "LLM_API_KEY 尚未設定：請編輯 .env 填入金鑰再 restart"
else
    set_bot_env LLM_API_KEY ""
    ok "LLM_BASE_URL=$BASE_URL、LLM_API_KEY 留空（自動讀 ~/vllm-server/vllm.env，換金鑰也不用改）"
fi
[ -z "$TOKEN" ] || set_bot_env DISCORD_BOT_TOKEN "$TOKEN"
[ -z "$CHANNEL_ID" ] || { set_bot_env ALLOWED_CHANNEL_ID "$CHANNEL_ID"; ok "ALLOWED_CHANNEL_ID=$CHANNEL_ID（只在這個頻道自動回，其他頻道要 @bot/私訊）"; }
HAS_TOKEN=1
grep -qE '^DISCORD_BOT_TOKEN=.{20,}$' "$ENV_BOT" && ! grep -q '^DISCORD_BOT_TOKEN=貼上' "$ENV_BOT" || HAS_TOKEN=0

# --- 4. systemd 服務 ------------------------------------------------------------
if [ "$SERVICE_ON" = 0 ]; then
    warn "略過服務註冊（--no-service）；手動執行：$HERE/.venv/bin/python $HERE/discord_bot.py"
    exit 0
fi
step "4. 註冊 systemd 服務 $BOT_SERVICE（開機自動啟動、掛掉自動重啟）"
if [ -n "$REMOTE_URL" ]; then
    UNIT_DESC="Discord bot（接遠端 gateway）"
    UNIT_AFTER="network-online.target"
else
    UNIT_DESC="Discord bot（接同一台的 vLLM）"
    UNIT_AFTER="network-online.target ${SERVICE:-vllm}.service"
fi
sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=$UNIT_DESC
After=$UNIT_AFTER
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=$HERE
Environment=PYTHONUNBUFFERED=1
ExecStart=$HERE/.venv/bin/python $HERE/discord_bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$BOT_SERVICE" >/dev/null 2>&1
if [ "$HAS_TOKEN" = 0 ]; then
    sudo systemctl stop "$BOT_SERVICE" 2>/dev/null || true
    step "還差一步：填 Discord bot token"
    echo "  1) nano $ENV_BOT   → DISCORD_BOT_TOKEN= 後面貼上 Discord bot token（不是 vLLM 金鑰；建立 bot 的步驟見 discord/doc/discord-bot.md）"
    echo "  2) sudo systemctl restart $BOT_SERVICE"
    echo "  3) journalctl -u $BOT_SERVICE -f   看到「[已上線]」就完成"
    exit 0
fi
sudo systemctl restart "$BOT_SERVICE"
printf '  等待上線'
for _ in $(seq 1 24); do
    if journalctl -u "$BOT_SERVICE" -n 50 --no-pager -o cat 2>/dev/null | grep -q '\[已上線\]'; then
        echo; ok "$(journalctl -u "$BOT_SERVICE" -n 50 --no-pager -o cat | grep '\[已上線\]' | tail -n 1)"
        step "完成"
        echo "  在 Discord 輸入 !help 試試看；狀態：sudo systemctl status $BOT_SERVICE；紀錄：journalctl -u $BOT_SERVICE -f"
        exit 0
    fi
    printf '.'; sleep 5
done
echo
warn "2 分鐘內沒看到上線訊息，最近的紀錄："
journalctl -u "$BOT_SERVICE" -n 20 --no-pager -o cat || true
warn "常見原因：token 貼錯（LoginFailure）、Developer Portal 沒開 MESSAGE CONTENT INTENT（PrivilegedIntentsRequired）"
