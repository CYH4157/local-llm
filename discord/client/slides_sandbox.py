"""
slides_sandbox.py — 在 LXD 沙盒（sandbox/setup-sandbox.sh 建的 pptx-sandbox）執行模型寫的 python-pptx 程式。

流程：清空 /home/runner/job → 放入 deck.py（＋範本）→ 以 runner 身分、無網路、限時執行
      → 產出 output.pptx → LibreOffice 轉 PDF → pdftoppm 轉 PNG → 拉回主機、拼成預覽圖
一次只跑一個工作（threading.Lock）。
"""

import base64
import glob
import io
import os
import shutil
import subprocess
import tempfile
import threading
import time

BOT_DIR = os.path.dirname(os.path.abspath(__file__))
SANDBOX = os.getenv("SANDBOX_NAME", "pptx-sandbox")
RUN_TIMEOUT = int(os.getenv("SANDBOX_TIMEOUT", "120"))
JOB = "/home/runner/job"
RUNNER = os.getenv("SANDBOX_RUNNER_UID", "1001")
OUT_DIR = os.path.join(BOT_DIR, "outputs")
TEMPLATE = os.path.join(BOT_DIR, "templates", "ppt_template.pptx")
MAX_PPTX_MB = 20

_lock = threading.Lock()


def _lxc() -> str | None:
    return shutil.which("lxc") or (os.path.exists("/snap/bin/lxc") and "/snap/bin/lxc") or None


def _run(args: list[str], timeout: int = 60, **kw) -> subprocess.CompletedProcess:
    return subprocess.run([_lxc(), *args], capture_output=True, text=True, timeout=timeout, **kw)


def available() -> str | None:
    """沙盒可用回傳 None，否則回傳原因。"""
    if not _lxc():
        return "主機沒有 LXD（lxc 指令）"
    try:
        r = _run(["list", SANDBOX, "-f", "csv", "-c", "s"], timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        return f"無法執行 lxc：{e}"
    if r.returncode != 0 or not r.stdout.strip():
        return f"找不到沙盒容器 {SANDBOX}（執行 sandbox/setup-sandbox.sh 建立）"
    if "RUNNING" not in r.stdout:
        _run(["start", SANDBOX], timeout=60)
    return None


def _exec_root(cmd: str, timeout: int = 60) -> subprocess.CompletedProcess:
    return _run(["exec", SANDBOX, "--", "bash", "-c", cmd], timeout=timeout)


def _exec_runner(cmd: str, timeout: int) -> subprocess.CompletedProcess:
    return _run(["exec", SANDBOX, "--user", RUNNER, "--group", RUNNER, "--cwd", JOB,
                 "--env", "HOME=/home/runner", "--env", "MPLBACKEND=Agg",
                 "--", "bash", "-c", cmd], timeout=timeout + 30)


def _grid(pngs: list[str], cols: int = 2, width: int = 640) -> list[bytes]:
    """把每頁縮圖拼成幾張總覽圖（每張最多 6 頁），省模型與 Discord 的流量。"""
    from PIL import Image, ImageDraw
    sheets, per = [], cols * 3
    for start in range(0, len(pngs), per):
        imgs = []
        for p in pngs[start:start + per]:
            im = Image.open(p).convert("RGB")
            im = im.resize((width, int(im.height * width / im.width)))
            imgs.append(im)
        h = max(i.height for i in imgs)
        rows = (len(imgs) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * width + (cols + 1) * 10, rows * (h + 34) + 10), "#d0d0d0")
        d = ImageDraw.Draw(sheet)
        for k, im in enumerate(imgs):
            x = 10 + (k % cols) * (width + 10)
            y = 10 + (k // cols) * (h + 34)
            d.text((x + 4, y + 4), f"Slide {start + k + 1}", fill="black")   # 預設字型沒有中文
            sheet.paste(im, (x, y + 22))
        buf = io.BytesIO()
        sheet.save(buf, "PNG", optimize=True)
        sheets.append(buf.getvalue())
    return sheets


def run_deck(code: str) -> dict:
    """
    執行一份投影片程式。回傳：
      ok, message（給模型看的文字：錯誤或成功摘要）, pptx（主機路徑）, previews（PNG bytes 清單）, pages
    """
    why = available()
    if why:
        return {"ok": False, "message": f"沙盒無法使用：{why}", "pptx": None, "previews": [], "pages": 0}
    with _lock:
        _exec_root(f"pkill -u runner; rm -rf {JOB}; install -d -o runner -g runner {JOB}")
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "deck.py")
            with open(src, "w", encoding="utf-8") as f:
                f.write(code)
            _run(["file", "push", src, f"{SANDBOX}{JOB}/deck.py", "--uid", RUNNER, "--gid", RUNNER])
            if os.path.isfile(TEMPLATE):
                _run(["file", "push", TEMPLATE, f"{SANDBOX}{JOB}/template.pptx", "--uid", RUNNER, "--gid", RUNNER])

            t0 = time.time()
            try:
                r = _exec_runner(f"timeout -k 5 {RUN_TIMEOUT} python3 deck.py 2>&1 | tail -c 4000", RUN_TIMEOUT)
            except subprocess.TimeoutExpired:
                _exec_root("pkill -9 -u runner")
                return {"ok": False, "message": f"程式執行超過 {RUN_TIMEOUT} 秒被中止", "pptx": None, "previews": [], "pages": 0}
            out = (r.stdout or "").strip()
            chk = _exec_root(f"stat -c %s {JOB}/output.pptx 2>/dev/null")
            if chk.returncode != 0:
                msg = "程式沒有產生 output.pptx。" + (f"\n程式輸出 / 錯誤：\n{out}" if out else "")
                return {"ok": False, "message": msg, "pptx": None, "previews": [], "pages": 0}
            if int(chk.stdout.strip() or 0) > MAX_PPTX_MB * 1024 * 1024:
                return {"ok": False, "message": f"output.pptx 超過 {MAX_PPTX_MB} MB，請縮小圖片", "pptx": None, "previews": [], "pages": 0}

            # 轉 PNG（LibreOffice → PDF → 每頁 PNG）
            _exec_runner("rm -rf render && mkdir render && "
                         "timeout 120 soffice --headless --convert-to pdf --outdir render output.pptx >/dev/null 2>&1 && "
                         "timeout 60 pdftoppm -png -r 50 render/output.pdf render/p", 150)
            os.makedirs(OUT_DIR, exist_ok=True)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            local = os.path.join(OUT_DIR, f"slides-{stamp}.pptx")
            _run(["file", "pull", f"{SANDBOX}{JOB}/output.pptx", local])
            rdir = os.path.join(tmp, "render")
            os.makedirs(rdir, exist_ok=True)
            ls = _exec_root(f"ls {JOB}/render/ 2>/dev/null | grep -E '^p-?[0-9]+\\.png$'")
            for name in ls.stdout.split():
                _run(["file", "pull", f"{SANDBOX}{JOB}/render/{name}", rdir])
            pngs = sorted(glob.glob(os.path.join(rdir, "p*.png")),
                          key=lambda p: int("".join(ch for ch in os.path.basename(p) if ch.isdigit()) or 0))
            previews = _grid(pngs) if pngs else []
            _exec_root("pkill -u runner")

        pages = len(pngs)
        msg = f"成功產生 output.pptx，共 {pages} 頁（{time.time() - t0:.0f} 秒）。"
        if out:
            msg += f"\n程式輸出：\n{out[-1500:]}"
        if not previews:
            msg += "\n（預覽圖轉換失敗，無法檢查版面）"
        return {"ok": True, "message": msg, "pptx": local, "previews": previews, "pages": pages}


def to_data_url(png: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(png).decode()
