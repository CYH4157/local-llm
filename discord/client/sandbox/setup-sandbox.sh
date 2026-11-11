#!/usr/bin/env bash
# =============================================================================
#  setup-sandbox.sh — 建立 / 更新「投影片沙盒」：LXD 容器 pptx-sandbox
#
#  模型寫的 python-pptx 程式只在這個容器裡執行：
#    • 非特權容器、以普通使用者 runner 執行
#    • 沒有網路（裝完套件後切斷）、限制 CPU / 記憶體 / 行程數、每次執行有時間上限
#    • 容器裡有 LibreOffice + 中文字型，用來把投影片轉成 PNG 給模型和使用者看
#
#  需求：snap 版 LXD、使用者在 lxd 群組（不需要 sudo）
#  用法：bash setup-sandbox.sh           建立或更新（重跑會暫時開網路裝套件，再切斷）
#        bash setup-sandbox.sh --reset   還原到乾淨快照（沙盒被弄亂時）
# =============================================================================
set -euo pipefail
NAME="${SANDBOX_NAME:-pptx-sandbox}"
die() { echo "[錯誤] $*" >&2; exit 1; }
step() { echo; echo "==== $* ===="; }

command -v lxc >/dev/null 2>&1 || die "沒有 lxc：sudo snap install lxd，並把自己加進 lxd 群組"
lxc list >/dev/null 2>&1 || die "無法使用 LXD：確認使用者在 lxd 群組（id 指令看得到 lxd）"

if [ "${1:-}" = "--reset" ]; then
    lxc restore "$NAME" clean && echo "已還原 $NAME 到乾淨快照"; exit 0
fi

step "1. LXD 初始化"
lxc storage list -f csv | grep -q . || lxd init --auto
echo "OK"

step "2. 容器 $NAME"
if ! lxc info "$NAME" >/dev/null 2>&1; then
    lxc launch ubuntu:22.04 "$NAME" -c limits.cpu=4 -c limits.memory=4GiB -c limits.processes=1024
fi
# 安裝期間需要網路：拿掉「切斷網路」的設定
if lxc config device show "$NAME" | grep -q '^eth0:'; then
    lxc config device remove "$NAME" eth0
    lxc restart "$NAME" 2>/dev/null || lxc start "$NAME"
fi
lxc start "$NAME" 2>/dev/null || true
lxc exec "$NAME" -- cloud-init status --wait >/dev/null || true
for _ in $(seq 1 30); do lxc exec "$NAME" -- getent hosts archive.ubuntu.com >/dev/null 2>&1 && break; sleep 2; done

step "3. 安裝 LibreOffice、中文字型、python-pptx（第一次約 3~5 分鐘）"
lxc exec "$NAME" -- bash -euc '
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends python3-pip libreoffice-impress fonts-noto-cjk \
    fonts-noto-color-emoji fonts-crosextra-carlito fonts-liberation poppler-utils fontconfig >/dev/null
pip3 install -q --upgrade "python-pptx>=1.0" matplotlib numpy
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
install -d -o runner -g runner /home/runner/.config/matplotlib /home/runner/job
cat > /home/runner/.config/matplotlib/matplotlibrc <<EOF
font.sans-serif: Noto Sans CJK TC, Noto Sans CJK JP, DejaVu Sans
axes.unicode_minus: False
EOF
chown -R runner:runner /home/runner
# Windows 常用中文字型 → Noto，讓預覽圖接近使用者在 PowerPoint 看到的樣子
cat > /etc/fonts/local.conf <<EOF
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias><family>微軟正黑體</family><prefer><family>Noto Sans CJK TC</family></prefer></alias>
  <alias><family>Microsoft JhengHei</family><prefer><family>Noto Sans CJK TC</family></prefer></alias>
  <alias><family>Microsoft JhengHei UI</family><prefer><family>Noto Sans CJK TC</family></prefer></alias>
  <alias><family>標楷體</family><prefer><family>Noto Serif CJK TC</family></prefer></alias>
  <alias><family>DFKai-SB</family><prefer><family>Noto Serif CJK TC</family></prefer></alias>
  <alias><family>新細明體</family><prefer><family>Noto Serif CJK TC</family></prefer></alias>
  <alias><family>PMingLiU</family><prefer><family>Noto Serif CJK TC</family></prefer></alias>
  <alias><family>Calibri</family><prefer><family>Carlito</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>Arial</family><prefer><family>Liberation Sans</family><family>DejaVu Sans</family></prefer></alias>
</fontconfig>
EOF
fc-cache -f >/dev/null
# 先跑一次 LibreOffice 建好設定檔，之後轉檔比較快
su runner -c "cd /tmp && soffice --headless --terminate_after_init" >/dev/null 2>&1 || true
apt-get clean
echo "runner uid=$(id -u runner)"
python3 -c "import pptx, matplotlib; print(\"python-pptx\", pptx.__version__, \"matplotlib\", matplotlib.__version__)"
fc-list :lang=zh family | head -3
'

step "4. 切斷網路、存快照"
lxc config device add "$NAME" eth0 none >/dev/null
lxc restart "$NAME"
if lxc exec "$NAME" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    die "容器還連得到網路，請檢查（lxc config device show $NAME）"
fi
echo "OK：容器已無網路"
lxc snapshot "$NAME" clean --reuse
echo "OK：快照 clean 已建立（bash $0 --reset 可還原）"
