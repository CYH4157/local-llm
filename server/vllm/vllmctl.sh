#!/usr/bin/env bash
# =============================================================================
#  vllmctl.sh — 管理 WSL 裡的 vLLM 服務（Windows 上雙擊 server\wsl2\vllmctl.cmd 就是執行這支）
#
#    info                     顯示給同學的連線資訊（網址、金鑰、安裝方式）
#    show                     顯示目前設定（金鑰遮蔽）、GPU 用量、KV cache 容量
#    status | logs            服務狀態 / 即時紀錄（Ctrl+C 離開）
#    start | stop | restart   啟動 / 停止（釋放 GPU）/ 重啟
#    presets                  列出內建模型組合
#    preset NAME              換成內建組合（small / laptop / quality / medium / large / xlarge）
#    model HF_ID [NAME] [MAX_LEN] [TOOL_PARSER]
#                             換成任意 Hugging Face 模型（先下載再切換）
#    models                   列出用過的模型（可直接 switch 回去，設定會保留）
#    switch [NAME|編號]        切換到用過的模型或內建組合；不加參數會列出選單
#    forget NAME              從清單移除一個模型（權重檔不刪）
#    set KEY VALUE            修改 vllm.env 的一個參數並重啟（例：set SERVE_MAX_LEN 24576）
#    new-key [KEY]            產生新的 API 金鑰（或指定金鑰），舊的立即失效
#    edit                     用 nano 編輯 vllm.env，存檔後重啟
#    bench                    跑標準測試（速度、長文件、工具呼叫、五人同時、中文、寫程式）
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# 改寫 vllm.env 的一行（值會正確跳脫雙引號，JSON 參數也能存）
set_var() {
    python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import re, sys
path, k, v = sys.argv[1:]
src = open(path).read()
v = v.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
line = f'{k}="{v}"'
src, n = re.subn(rf'^{k}=.*$', lambda _: line, src, flags=re.M)
open(path, "w").write(src if n else src.rstrip("\n") + "\n" + line + "\n")
PY
}

# 重啟並等到就緒；失敗時印出真正的錯誤原因
restart_and_wait() {
    local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
    sudo systemctl restart "$SERVICE"
    printf '  等待載入'
    for _ in $(seq 1 360); do
        if curl -fsS -m 3 "http://127.0.0.1:${SERVE_PORT:-8000}/health" >/dev/null 2>&1; then
            echo; ok "就緒"
            save_profile
            journalctl -u "$SERVICE" --since "$since" --no-pager -o cat | grep -E "GPU KV cache size" | tail -n 1 | sed 's/^.*\] /  /'
            return 0
        fi
        local err
        err="$(journalctl -u "$SERVICE" --since "$since" --no-pager -o cat | grep -E '^(RuntimeError|ValueError|torch\.OutOfMemoryError|OSError|ImportError)' | grep -v 'Engine core initialization failed' | head -n 3)"
        if [ -n "$err" ]; then
            echo; warn "啟動失敗，原因："; echo "$err"
            warn "常見處理：調小 SERVE_MAX_LEN（vllmctl set SERVE_MAX_LEN 16384）或換小一點的模型；完整紀錄：vllmctl logs"
            return 1
        fi
        printf '.'; sleep 5
    done
    echo; die "等太久，查看： vllmctl logs"
}

# 把目前模型的設定存成 models/<名稱>.env（直接複製 vllm.env 裡的那幾行，跳脫方式不變）
save_profile() {
    mkdir -p "$PROFILE_DIR"
    grep -E "^($PROFILE_KEYS)=" "$ENV_FILE" > "$PROFILE_DIR/$SERVE_NAME.env"
}

# 把 models/<名稱>.env 的設定寫回 vllm.env
apply_profile() {
    python3 - "$ENV_FILE" "$1" <<'PY'
import re, sys
env, prof = sys.argv[1:]
src = open(env).read()
for line in open(prof).read().splitlines():
    k = line.split("=", 1)[0]
    src, n = re.subn(rf'^{k}=.*$', lambda _: line, src, flags=re.M)
    if not n:
        src = src.rstrip("\n") + "\n" + line + "\n"
open(env, "w").write(src)
PY
}

profile_names() { [ -d "$PROFILE_DIR" ] && find "$PROFILE_DIR" -maxdepth 1 -name '*.env' -printf '%f\n' | sed 's/\.env$//' | sort; }

# 用過的模型清單；* = 目前使用中
list_profiles() {
    local i=0 n m len dl
    # 中文字佔兩格，標題直接手動對齊
    echo "  #   名稱$(printf '%21s')Hugging Face 模型$(printf '%30s')上下文  權重"
    while read -r n; do
        [ -n "$n" ] || continue
        i=$((i + 1))
        m="$(sed -n 's/^SERVE_MODEL="\(.*\)"$/\1/p' "$PROFILE_DIR/$n.env")"
        len="$(sed -n 's/^SERVE_MAX_LEN="\(.*\)"$/\1/p' "$PROFILE_DIR/$n.env")"
        dl="未下載"; [ -d "$HOME/.cache/huggingface/hub/models--${m//\//--}" ] && dl="已下載"
        printf '%s %-3s %-24s %-46s %-7s %s\n' "$([ "$n" = "$SERVE_NAME" ] && echo '*' || echo ' ')" "$i" "$n" "$m" "$len" "$dl"
    done < <(profile_names)
    echo
    echo "  內建組合（也可以 switch）：small / laptop / quality / medium / large / xlarge（vllmctl presets 看說明）"
}

client_reminder() {
    warn "模型名稱或上下文變了：每台 client 請重跑一次 install-client（Windows 雙擊 opencode\\client\\install-client.cmd）"
}

cmd="${1:-info}"; shift || true
load_env
# 第一次使用（或舊版升級上來）時，先把目前的模型存進清單
[ -f "$PROFILE_DIR/$SERVE_NAME.env" ] || save_profile
case "$cmd" in
    info)
        LIP="$(lan_ip)"; LHOST="$(lan_host)"; HOSTIP="${LHOST:-$LIP}"; HOSTIP="${HOSTIP:-<筆電IP>}"
        echo "模型名稱：$SERVE_NAME   ($SERVE_MODEL, 上下文 $SERVE_MAX_LEN)"
        echo "vLLM 網址：http://$HOSTIP:$SERVE_PORT/v1"
        [ -n "$LHOST" ] && [ -n "$LIP" ] && echo "目前 IP  ：http://$LIP:$SERVE_PORT/v1（DHCP 會換，給同學請用上面的網址）"
        echo "API 金鑰 ：$SERVE_API_KEY"
        echo
        echo "同學的 Windows 電腦：複製 opencode 資料夾 → 雙擊 opencode\\client\\install-client.cmd → 貼上上面的網址與金鑰"
        echo "同學的 Ubuntu 電腦 ：bash opencode/client/install-client.sh --url http://$HOSTIP:$SERVE_PORT/v1 --key $SERVE_API_KEY --name laptop"
        echo "先測試連線        ：瀏覽器開 http://$HOSTIP:$SERVE_PORT/v1/models（看到 Unauthorized 代表連得到）"
        ;;
    show)
        echo "設定檔：$ENV_FILE"
        grep -E '^(SERVE_|VLLM_|HF_TOKEN|CUDA_)' "$ENV_FILE" \
            | sed -E 's/^(SERVE_API_KEY=").{8}.*"/\1********（vllmctl info 可看完整金鑰）"/; s/^(HF_TOKEN=").+"/\1********"/'
        echo
        nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader | sed 's/^/GPU：/'
        journalctl -u "$SERVICE" --no-pager -o cat 2>/dev/null | grep -E "GPU KV cache size" | tail -n 1 | sed 's/^.*\] /KV cache：/'
        ;;
    status)
        systemctl status "$SERVICE" --no-pager -n 5 || true
        nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv || true
        ;;
    logs)    journalctl -u "$SERVICE" -f ;;
    stop)    sudo systemctl stop "$SERVICE"; ok "已停止，GPU 已釋放（vllmctl start 重新啟動）" ;;
    start|restart) restart_and_wait ;;
    presets) list_presets ;;
    preset)
        [ -n "${1:-}" ] || { list_presets; die "用法：vllmctl preset NAME"; }
        gpu_detect; apply_preset "$1"
        save_profile
        set_var SERVE_MODEL "$PRESET_MODEL";        set_var SERVE_NAME "$PRESET_NAME"
        set_var SERVE_MAX_LEN "$PRESET_MAX_LEN";    set_var SERVE_GPU_UTIL "$PRESET_GPU_UTIL"
        set_var SERVE_TOOL_PARSER "$PRESET_TOOL_PARSER"; set_var SERVE_EXTRA_ARGS "$PRESET_EXTRA"
        ok "已換成 $1：$PRESET_MODEL（上下文 $PRESET_MAX_LEN）"
        hf_download "$PRESET_MODEL"
        load_env; restart_and_wait && client_reminder
        ;;
    model)
        [ -n "${1:-}" ] || die "用法：vllmctl model HF_ID [NAME] [MAX_LEN] [TOOL_PARSER]，例：vllmctl model Qwen/Qwen3-8B-AWQ qwen3-8b 32768 hermes"
        M="$1"; N="${2:-$(basename "$1" | tr '[:upper:]' '[:lower:]')}"; L="${3:-$SERVE_MAX_LEN}"; T="${4:-hermes}"
        hf_download "$M"
        save_profile
        set_var SERVE_MODEL "$M"; set_var SERVE_NAME "$N"; set_var SERVE_MAX_LEN "$L"; set_var SERVE_TOOL_PARSER "$T"
        set_var SERVE_EXTRA_ARGS "$BASE_EXTRA"
        ok "已換成 $M（名稱 $N，上下文 $L，tool parser $T）"
        warn "SERVE_EXTRA_ARGS 已重設為基本值；思考型模型可再加：vllmctl set SERVE_EXTRA_ARGS \"$BASE_EXTRA --reasoning-parser qwen3\""
        load_env; restart_and_wait && client_reminder
        ;;
    models) list_profiles ;;
    switch)
        T="${1:-}"
        if [ -z "$T" ]; then
            list_profiles
            read -rp "  要切換到哪一個（輸入編號或名稱，Enter 取消）：" T
            [ -n "$T" ] || exit 0
        fi
        # 輸入編號 → 對應的名稱
        if [[ "$T" =~ ^[0-9]+$ ]]; then
            N="$(profile_names | sed -n "${T}p")"
            [ -n "$N" ] || die "沒有第 $T 個模型"
            T="$N"
        fi
        [ "$T" != "$SERVE_NAME" ] || { ok "目前已經是 $T"; exit 0; }
        if [ -f "$PROFILE_DIR/$T.env" ]; then
            save_profile   # 先存目前模型的設定（例如用 set 調過的上下文）
            apply_profile "$PROFILE_DIR/$T.env"
            load_env
            hf_download "$SERVE_MODEL"
        else
            # 不在清單裡就當成內建組合（apply_preset 認不得會報錯）
            gpu_detect; apply_preset "$T"
            save_profile
            set_var SERVE_MODEL "$PRESET_MODEL";        set_var SERVE_NAME "$PRESET_NAME"
            set_var SERVE_MAX_LEN "$PRESET_MAX_LEN";    set_var SERVE_GPU_UTIL "$PRESET_GPU_UTIL"
            set_var SERVE_TOOL_PARSER "$PRESET_TOOL_PARSER"; set_var SERVE_EXTRA_ARGS "$PRESET_EXTRA"
            load_env
            hf_download "$SERVE_MODEL"
        fi
        ok "切換到 $SERVE_NAME：$SERVE_MODEL（上下文 $SERVE_MAX_LEN）"
        restart_and_wait && client_reminder
        ;;
    forget)
        [ -n "${1:-}" ] || die "用法：vllmctl forget NAME（vllmctl models 看名稱）"
        [ "$1" != "$SERVE_NAME" ] || die "$1 正在使用中，先 switch 到別的模型再移除"
        [ -f "$PROFILE_DIR/$1.env" ] || die "清單裡沒有 $1"
        rm -f "$PROFILE_DIR/$1.env"
        ok "已從清單移除 $1（權重還在 ~/.cache/huggingface，要刪請用 $APP_DIR/.venv/bin/hf cache delete）"
        ;;
    set)
        [ $# -ge 2 ] || die "用法：vllmctl set KEY VALUE（例：vllmctl set SERVE_MAX_LEN 24576）"
        [[ "$1" =~ ^(SERVE_[A-Z_]+|VLLM_[A-Z0-9_]+|HF_TOKEN|CUDA_VISIBLE_DEVICES)$ ]] \
            || die "只能修改 SERVE_*、VLLM_*、HF_TOKEN、CUDA_VISIBLE_DEVICES"
        K="$1"; shift; set_var "$K" "$*"
        ok "$K 已更新"
        load_env; restart_and_wait
        case "$K" in SERVE_NAME|SERVE_MAX_LEN|SERVE_MODEL|SERVE_PORT) client_reminder ;; SERVE_API_KEY) warn "金鑰變了：每台 client 要用新金鑰重跑 install-client" ;; esac
        ;;
    new-key)
        set_var SERVE_API_KEY "${1:-$(gen_key)}"
        load_env; restart_and_wait
        ok "新金鑰：$SERVE_API_KEY"
        warn "舊金鑰已失效：每台 client 要用新金鑰重跑 install-client"
        ;;
    edit)
        "${EDITOR:-nano}" "$ENV_FILE"
        load_env; restart_and_wait
        ;;
    bench)
        mkdir -p ~/bench-results
        out=~/bench-results/"$SERVE_NAME-$(date +%Y%m%d-%H%M).md"
        python3 "$HERE/bench.py" "$SERVE_NAME (${SERVE_MAX_LEN})" "$out"
        ok "結果存在 $out"
        ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
