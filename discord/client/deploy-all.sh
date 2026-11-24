#!/usr/bin/env bash
# 在 Ubuntu 伺服器上一次部署 novel / webgame / stock / counselor 四支獨立 Discord Bot。
# token 只由使用者填入各自的 .env.<名稱>；本腳本不接受 token 參數，也不輸出環境檔內容。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_URL="https://inner-medusa.genai.nchc.org.tw/v1"
REMOTE_MODEL="Kimi-K3"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[提醒]\033[0m %s\n' "$*"; }

# 欄位順序：實例名稱｜限定頻道 ID｜SYSTEM_PROMPT（必須保持單行）
BOTS='
novel|1574256936424177745|你是「小說家」，熱愛故事與文字的小說創作者。使用自然的繁體中文，主動接話、延續話題，也能一起發想角色、世界觀與劇情；不要只給制式建議，回覆要有靈感但避免每次都被動地長篇大論。
webgame|1574257038408810546|你是「網站小遊戲教練」，擅長用 HTML、CSS、JavaScript 帶新手做網站與小遊戲。使用繁體中文，從使用者的程度出發，將步驟拆小、提供可執行的簡短範例並主動鼓勵嘗試；不確定就先問清楚，不要假裝已執行程式。
stock|1574257090669715526|你是「股市反指標」，熱血、愛自嘲自己看反方向，以輕鬆幽默的繁體中文聊投資心情。目前只有一般聊天能力，沒有即時行情、中文搜尋或新聞推播；不得編造價格、數據或新聞，不給保證獲利或個人化投資建議，必要時提醒投資有風險。
counselor|1574257436389548132|你是「陪伴型朋友」，像朋友一樣先傾聽、接納感受，不說教、不急著給長篇建議。使用溫暖自然的繁體中文，以一至三句簡短回覆為主，用開放式問題陪伴對方整理感受；不冒充心理師或做醫療診斷，面臨即時危險時鼓勵立即聯繫可信賴的人與當地緊急協助。
'

# 新實例可沿用預設 .env 的 NCHC 設定，但一定要把 Discord token 改成佔位值，
# 以免新 Bot 誤用 nchc-bot 身分。既有新實例環境檔則保留使用者填好的 token。
prepare_env() {
    local name="$1" prompt="$2"
    python3 - "$HERE" "$name" "$prompt" <<'PY'
import os
from pathlib import Path
import sys

root, name, prompt = sys.argv[1:]
if "\n" in prompt or "\r" in prompt:
    raise SystemExit("SYSTEM_PROMPT 必須是單行")
target = root_path = Path(root) / f".env.{name}"
created = not target.exists()
if created:
    source = Path(root) / ".env"
    if not source.is_file():
        source = Path(root) / ".env.example"
    if not source.is_file():
        raise SystemExit("找不到 .env 或 .env.example，無法建立新實例環境檔")
    text = source.read_text(encoding="utf-8-sig")
else:
    text = target.read_text(encoding="utf-8-sig")

def set_value(lines, key, value):
    prefix = key + "="
    for i, line in enumerate(lines):
        if line.startswith(prefix):
            lines[i] = prefix + value
            return
    lines.append(prefix + value)

lines = text.splitlines()
if created:
    set_value(lines, "DISCORD_BOT_TOKEN", "______")
set_value(lines, "SYSTEM_PROMPT", prompt)
data = "\n".join(lines) + "\n"
if created:
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(data)
else:
    target.write_text(data, encoding="utf-8", newline="\n")
os.chmod(target, 0o600)
PY
}

prepare_one() {
    local name="$1" channel="$2" prompt="$3"
    step "準備 $name：.env.$name（頻道 $channel）"
    prepare_env "$name" "$prompt"
    bash "$HERE/deploy.sh" --name "$name" --remote "$REMOTE_URL" \
        --model "$REMOTE_MODEL" --channel "$channel" --no-service
}

install_one() {
    local name="$1" channel="$2"
    step "註冊／更新 discord-bot-$name（尚未填 token 時保持停止）"
    bash "$HERE/deploy.sh" --name "$name" --remote "$REMOTE_URL" \
        --model "$REMOTE_MODEL" --channel "$channel"
}

SUDO_READY=1
if ! sudo -n true 2>/dev/null; then
    SUDO_READY=0
    warn "目前沒有可非互動使用的 sudo 權限；先準備四個環境檔，不啟動任何 Bot。"
fi

while IFS='|' read -r name channel prompt; do
    [ -n "$name" ] || continue
    prepare_one "$name" "$channel" "$prompt"
done <<EOF
$BOTS
EOF

if [ "$SUDO_READY" -eq 0 ]; then
    cat <<'MSG'

環境檔已準備，但 systemd 服務尚未註冊。請在互動式 SSH 終端機執行：
  sudo -v
  cd ~/local-llm/discord/client
  bash deploy-all.sh

腳本會建立四個服務；token 仍是佔位值時，服務會保持停止。
接著自行編輯 .env.novel、.env.webgame、.env.stock、.env.counselor，
只填入各自 Discord Application 的 token，再重新執行 bash deploy-all.sh。
MSG
    exit 0
fi

while IFS='|' read -r name channel prompt; do
    [ -n "$name" ] || continue
    install_one "$name" "$channel"
done <<EOF
$BOTS
EOF

step "四實例部署流程完成"
printf '%s\n' '檢查：systemctl status discord-bot-novel discord-bot-webgame discord-bot-stock discord-bot-counselor --no-pager'
printf '%s\n' '既有 nchc-bot：systemctl status discord-bot --no-pager（本腳本不修改或重啟它）'
printf '%s\n' '尚未填 token 的服務應保持停止；填好各自 .env.<名稱> 後再執行 bash deploy-all.sh。'
