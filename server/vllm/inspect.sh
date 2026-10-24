#!/usr/bin/env bash
# =============================================================================
#  inspect.sh — 檢查這台 Ubuntu 上現在是怎麼跑 vLLM 的（只讀取，不會改任何東西）
#
#    bash inspect.sh
#
#  用途：清理舊的部署、或換成本 repo 的部署方式之前，先看清楚現況。
#  輸出裡的 API 金鑰、Hugging Face token 會自動遮蔽，可以直接貼給別人看。
# =============================================================================
set -u
h() { printf '\n\033[36m== %s ==\033[0m\n' "$1"; }
mask() { sed -E 's/(sk-[A-Za-z]*-?)[A-Za-z0-9_-]{6,}/\1********/g; s/hf_[A-Za-z0-9]{6,}/hf_********/g'; }

h "主機"
echo "$(hostname)  $( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}" )  使用者：$(whoami)"
uptime -p 2>/dev/null

h "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
    echo "-- GPU 上的程序（pid, 名稱, 顯存）"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
else
    echo "沒有 nvidia-smi"
fi

h "監聽中的 port（8000 vLLM / 8080 llama-swap / 11434 Ollama / 4096 opencode）"
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(8000|8001|8080|11434|4096)[[:space:]]/' | mask

h "跟 vLLM / LLM 有關的程序"
ps -eo pid,user,etime,args 2>/dev/null | grep -iE 'vllm|llama-swap|ollama|sglang|text-generation|tgi' | grep -v -E 'grep|inspect.sh' | cut -c1-220 | mask

h "systemd 服務"
systemctl list-unit-files --type=service --no-pager 2>/dev/null | grep -iE 'vllm|llama|ollama|opencode|tailscale' || echo "（沒有相關服務）"
for s in vllm llama-swap ollama; do
    if systemctl cat "$s" >/dev/null 2>&1; then
        echo "-- $s：$(systemctl is-active "$s" 2>/dev/null) / $(systemctl is-enabled "$s" 2>/dev/null)"
        systemctl cat "$s" 2>/dev/null | grep -E '^(ExecStart|User|WorkingDirectory|EnvironmentFile)=' | mask
    fi
done

h "Docker 容器"
if command -v docker >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || echo "（沒有權限，可用 sudo docker ps -a 查看）"
else
    echo "沒有安裝 docker"
fi

h "tmux / screen（手動在背景跑的）"
tmux ls 2>/dev/null || echo "（沒有 tmux session）"
screen -ls 2>/dev/null | grep -E '^\s+[0-9]+\.' || echo "（沒有 screen session）"

h "crontab"
crontab -l 2>/dev/null | grep -vE '^\s*(#|$)' | mask || true
echo "（以上沒有內容 = 沒有排程）"

h "本專案相關的資料夾"
for d in ~/vllm-server ~/vllm-opencode-setup ~/opencode ~/local-llm ~/llm ~/.opencode ~/.config/opencode ~/bench-results; do
    [ -e "$d" ] && printf '%-32s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done
echo "-- 其他可能的 vLLM 環境（venv / conda）"
ls -d ~/*/.venv ~/*venv* ~/miniconda3/envs/* ~/anaconda3/envs/* 2>/dev/null | head -10

h "vllm.env（新舊版本共用的設定檔，金鑰已遮蔽）"
if [ -f ~/vllm-server/vllm.env ]; then
    grep -E '^(SERVE_|VLLM_|HF_TOKEN|CUDA_)' ~/vllm-server/vllm.env | mask
    echo "-- 用過的模型清單（新版 vllmctl 才有）"
    ls ~/vllm-server/models 2>/dev/null || echo "（沒有 → 是舊版）"
else
    echo "沒有 ~/vllm-server/vllm.env"
fi
echo "-- 管理腳本版本"
for f in ~/vllm-server/vllmctl.sh ~/opencode/vllmctl.sh ~/vllm-opencode-setup/vllmctl.sh ~/local-llm/server/vllm/vllmctl.sh; do
    [ -f "$f" ] && echo "$f：$(grep -qE '^\s+switch\)' "$f" && echo '新版（有 switch）' || echo '舊版（沒有 switch）')"
done

h "下載的模型（Hugging Face 快取）"
# 新版快取把權重放在共用的 hub/blobs，用 du 看各模型資料夾會不準 → 優先用 hf cache ls
HF="$HOME/vllm-server/.venv/bin/hf"; [ -x "$HF" ] || HF="$(command -v hf || true)"
if [ -n "$HF" ]; then
    HF_HUB_DISABLE_UPDATE_CHECK=1 "$HF" cache ls 2>/dev/null | grep -v -i hint || echo "（沒有）"
else
    du -sh ~/.cache/huggingface/hub 2>/dev/null | awk '{print "  快取總大小："$1"（沒有 hf 工具，無法列出各模型大小）"}'
fi
df -h ~ 2>/dev/null | tail -1 | awk '{print "家目錄所在磁碟：已用 "$3" / 共 "$2"，剩 "$4}'

h "防火牆 / Tailscale"
if command -v ufw >/dev/null 2>&1; then
    sudo -n ufw status 2>/dev/null || echo "ufw：需要 sudo 才能查看（sudo ufw status）"
fi
command -v tailscale >/dev/null 2>&1 && { tailscale status 2>/dev/null | head -3 || echo "tailscale 已安裝但沒有登入"; } || echo "沒有安裝 tailscale"

echo
echo "檢查完成（沒有修改任何東西）。"
