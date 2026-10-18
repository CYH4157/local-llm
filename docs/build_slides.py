"""
build_slides.py — 產生「實驗室本地 LLM 使用教學」投影片（docs/實驗室本地LLM使用教學.pptx）

修改內容後重新產生：
    .venv\\Scripts\\python.exe docs\\build_slides.py
"""

import os

from lxml import etree
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_CONNECTOR, MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.oxml.ns import qn
from pptx.util import Emu, Inches, Pt

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "實驗室本地LLM使用教學.pptx")

# --- 配色（沿用舊版投影片）與字型 -----------------------------------------
NAVY   = RGBColor(0x0F, 0x1B, 0x2D)   # 深色頁背景
NAVY2  = RGBColor(0x1C, 0x2B, 0x44)   # 深色頁上的卡片
INK    = RGBColor(0x1B, 0x24, 0x33)   # 標題文字
BODY   = RGBColor(0x4A, 0x55, 0x68)   # 內文
MUTED  = RGBColor(0x8B, 0x9B, 0xB4)   # 註解 / 頁尾
BLUE   = RGBColor(0x25, 0x63, 0xC9)   # 主要強調色
ORANGE = RGBColor(0xF0, 0xA0, 0x4B)   # 第二強調色
BG     = RGBColor(0xF6, 0xF5, 0xF1)   # 內容頁背景
CARD   = RGBColor(0xFD, 0xFC, 0xF9)   # 卡片
BORDER = RGBColor(0xE2, 0xDF, 0xD8)
TINT   = RGBColor(0xE6, 0xED, 0xF8)   # 表頭 / 淡藍底
CODEBG = RGBColor(0x1B, 0x24, 0x33)
CODETX = RGBColor(0xE6, 0xE9, 0xEF)
WHITE  = RGBColor(0xFF, 0xFF, 0xFF)
RED    = RGBColor(0xC2, 0x41, 0x0C)

FONT = "微軟正黑體"
MONO = "Consolas"

W, H = Inches(13.333), Inches(7.5)
MX = Inches(0.6)                      # 左右邊界
CW = W - MX * 2                       # 內容寬度
DECK = "實驗室本地 LLM 使用教學"

prs = Presentation()
prs.slide_width, prs.slide_height = W, H
BLANK = prs.slide_layouts[6]
_page = [0]


# =============================================================================
#  基本工具
# =============================================================================
def _font(run, size, color, bold=False, mono=False):
    f = run.font
    f.size = Pt(size)
    f.bold = bold
    f.color.rgb = color
    f.name = MONO if mono else FONT
    rPr = run._r.get_or_add_rPr()
    for old in rPr.findall(qn("a:ea")):
        rPr.remove(old)
    ea = etree.SubElement(rPr, qn("a:ea"))
    ea.set("typeface", FONT)           # 中文一律微軟正黑體（程式碼區的中文註解也是）
    latin = rPr.find(qn("a:latin"))
    if latin is not None:
        latin.addnext(ea)


def text(slide, x, y, w, h, paras, size=16, color=BODY, bold=False, mono=False,
         align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, space=6, line=None):
    """paras：字串、或段落清單；每段是字串，或 [(文字, {size,color,bold,mono}), ...]"""
    tb = slide.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    if isinstance(paras, str):
        paras = [paras]
    for i, para in enumerate(paras):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.space_after = Pt(space)
        if line:
            p.line_spacing = line
        runs = para if isinstance(para, list) else [(para, {})]
        for t, o in runs:
            r = p.add_run()
            r.text = t
            _font(r, o.get("size", size), o.get("color", color), o.get("bold", bold), o.get("mono", mono))
    return tb


def box(slide, x, y, w, h, fill=CARD, line=BORDER, radius=0.06, shape=MSO_SHAPE.ROUNDED_RECTANGLE):
    s = slide.shapes.add_shape(shape, x, y, w, h)
    s.fill.solid()
    s.fill.fore_color.rgb = fill
    if line is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line
        s.line.width = Pt(0.75)
    s.shadow.inherit = False
    if shape == MSO_SHAPE.ROUNDED_RECTANGLE:
        s.adjustments[0] = radius
    s.text_frame.text = ""
    return s


def badge(slide, x, y, d, label, fill=BLUE, color=WHITE, size=14):
    c = box(slide, x, y, d, d, fill=fill, line=None, shape=MSO_SHAPE.OVAL)
    tf = c.text_frame
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    p = tf.paragraphs[0]
    p.alignment = PP_ALIGN.CENTER
    r = p.add_run()
    r.text = label
    _font(r, size, color, bold=True)
    return c


def arrow(slide, x1, y1, x2, y2, color=MUTED, width=1.5, dash=False):
    # 座標一定要是整數 EMU：連接線不會自動取整，小數會讓 PowerPoint 打不開檔案
    c = slide.shapes.add_connector(MSO_CONNECTOR.STRAIGHT, int(x1), int(y1), int(x2), int(y2))
    c.line.color.rgb = color
    c.line.width = Pt(width)
    ln = c.line._get_or_add_ln()
    if dash:
        d = etree.SubElement(ln, qn("a:prstDash"))
        d.set("val", "dash")
    tail = etree.SubElement(ln, qn("a:tailEnd"))
    tail.set("type", "triangle")
    return c


def code(slide, x, y, w, h, lines, size=13):
    """深色程式碼區塊。# 開頭 = 註解（灰）；> 開頭 = 重點（橘，> 不會顯示）"""
    box(slide, x, y, w, h, fill=CODEBG, line=None, radius=0.04)
    paras = []
    for ln in lines:
        if ln.startswith("#"):
            paras.append([(ln, {"color": MUTED})])
        elif ln.startswith(">"):
            paras.append([(ln[1:].lstrip(), {"color": ORANGE, "bold": True})])
        else:
            paras.append([(ln, {"color": CODETX})])
    text(slide, x + Inches(0.3), y + Inches(0.25), w - Inches(0.6), h - Inches(0.5),
         paras, size=size, mono=True, space=4)


def table(slide, x, y, w, rows, colw, size=13, rowh=0.42, header=True, mono_cols=()):
    nrows, ncols = len(rows), len(rows[0])
    gt = slide.shapes.add_table(nrows, ncols, x, y, w, Inches(rowh * nrows))
    tbl = gt.table
    tblPr = tbl._tbl.tblPr
    style = tblPr.find(qn("a:tableStyleId"))
    if style is not None:
        style.text = "{5940675A-B579-460E-94D1-54222C63F5DA}"   # 無樣式、表格格線
    tblPr.set("firstRow", "0")
    tblPr.set("bandRow", "0")
    total = sum(colw)
    for i, cw in enumerate(colw):
        tbl.columns[i].width = int(w * cw / total)
    for r in range(nrows):
        tbl.rows[r].height = Inches(rowh)
        for c in range(ncols):
            cell = tbl.cell(r, c)
            is_head = header and r == 0
            cell.fill.solid()
            cell.fill.fore_color.rgb = TINT if is_head else CARD
            cell.margin_left = cell.margin_right = Inches(0.12)
            cell.margin_top = cell.margin_bottom = Inches(0.05)
            cell.vertical_anchor = MSO_ANCHOR.MIDDLE
            tf = cell.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            r_ = p.add_run()
            r_.text = rows[r][c]
            _font(r_, size, INK if is_head else BODY, bold=is_head,
                  mono=(c in mono_cols and not is_head))
            # 框線（a:lnL…）在 schema 裡必須排在填色（a:solidFill）之前，所以插在最前面
            tcPr = cell._tc.get_or_add_tcPr()
            for i, tag in enumerate(("a:lnL", "a:lnR", "a:lnT", "a:lnB")):
                ln = etree.Element(qn(tag))
                ln.set("w", "9525")
                sf = etree.SubElement(ln, qn("a:solidFill"))
                clr = etree.SubElement(sf, qn("a:srgbClr"))
                clr.set("val", "E2DFD8")
                tcPr.insert(i, ln)
    return gt


# =============================================================================
#  頁面骨架
# =============================================================================
def new_slide(dark=False):
    s = prs.slides.add_slide(BLANK)
    s.background.fill.solid()
    s.background.fill.fore_color.rgb = NAVY if dark else BG
    _page[0] += 1
    return s


def header(s, kicker, title, dark=False):
    text(s, MX, Inches(0.45), CW, Inches(0.3), kicker, size=12, color=ORANGE if dark else BLUE, bold=True)
    text(s, MX, Inches(0.78), CW, Inches(0.7), title, size=30, color=WHITE if dark else INK, bold=True)


def footer(s, dark=False):
    text(s, MX, H - Inches(0.5), Inches(6), Inches(0.25), f"{DECK} · {_page[0]:02d}",
         size=10, color=MUTED)


def notes(s, t):
    s.notes_slide.notes_text_frame.text = t


def content_slide(kicker, title, note):
    s = new_slide()
    header(s, kicker, title)
    footer(s)
    notes(s, note)
    return s


TOP = Inches(1.75)   # 內容區起點


# =============================================================================
#  1. 封面
# =============================================================================
s = new_slide(dark=True)
text(s, MX, Inches(2.0), CW, Inches(0.35), "實驗室本地 LLM · 使用教學", size=14, color=ORANGE, bold=True)
text(s, MX, Inches(2.45), CW, Inches(1.0), "自架 vLLM × opencode × Discord", size=44, color=WHITE, bold=True)
text(s, MX, Inches(3.55), CW, Inches(0.5),
     "一台 Windows 筆電跑模型，同學用 opencode 寫程式、用 Discord 產生 PPT / Word / Excel",
     size=18, color=RGBColor(0xBF, 0xC8, 0xD6))
x = MX
for chip in ("vLLM :8000", "opencode", "Discord bot", "Windows + WSL2", "學校 VPN / Funnel"):
    wch = Inches(0.35 + len(chip) * 0.13)
    c = box(s, x, Inches(4.45), wch, Inches(0.42), fill=NAVY2, line=None, radius=0.5)
    text(s, x, Inches(4.45), wch, Inches(0.42), chip, size=12, color=CODETX,
         align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE, space=0)
    x += wch + Inches(0.15)
text(s, MX, H - Inches(0.75), CW, Inches(0.3),
     "GitHub：CYH4157/local-llm · 完整步驟：完整步驟.md", size=11, color=MUTED)
notes(s, "這份教學說明實驗室怎麼用一台 Windows 筆電架設語言模型（vLLM），"
         "讓同學透過 opencode 寫程式、寫作業，並透過 Discord bot 產生簡報、Word、Excel 草稿。"
         "模型、程式碼與對話都留在實驗室，不經過雲端 API。")

# =============================================================================
#  2. 目錄
# =============================================================================
s = content_slide("目錄", "今天的內容",
                  "前兩段是系統介紹與一次性的主機安裝，第三、四段是每天會用到的 opencode 與 Discord bot，"
                  "第五段是不在實驗室時怎麼連，最後是管理者需要知道的金鑰、換模型與排錯。")
items = [("01", "認識系統", "三個元件、整體架構、模型實測"),
         ("02", "筆電主機安裝", "雙擊 setup-host.cmd 一次完成"),
         ("03", "同學使用 opencode", "安裝 client、基本操作、提問技巧"),
         ("04", "Discord bot", "產生 PPT / Word / Excel 草稿"),
         ("05", "不在實驗室時", "在家用學校 VPN、校外用 Funnel"),
         ("06", "管理與排錯", "金鑰、換模型、安全性、疑難排解")]
cw, ch, gap = (CW - Inches(0.5)) / 3, Inches(2.1), Inches(0.25)
for i, (n, t, d) in enumerate(items):
    x = MX + (cw + gap) * (i % 3)
    y = TOP + (ch + gap) * (i // 3)
    box(s, x, y, cw, ch)
    text(s, x + Inches(0.35), y + Inches(0.35), cw - Inches(0.7), Inches(0.5), n, size=24, color=BLUE, bold=True)
    text(s, x + Inches(0.35), y + Inches(0.95), cw - Inches(0.7), Inches(0.45), t, size=20, color=INK, bold=True)
    text(s, x + Inches(0.35), y + Inches(1.45), cw - Inches(0.7), Inches(0.5), d, size=14, color=BODY)

# =============================================================================
#  3. 三個元件
# =============================================================================
s = content_slide("01 認識系統", "三個元件各司其職",
                  "vLLM 是唯一跑模型的地方，在筆電的 WSL 裡。opencode 和 Discord bot 都只是呼叫它的程式，"
                  "所以兩者共用同一個模型和同一張顯卡。同學的電腦不需要顯卡。")
comps = [("🧠", "vLLM", "推論伺服器：把模型載入 GPU，提供 OpenAI 相容 API，支援 tool calling。",
          "筆電 WSL · 服務 vllm · 埠 8000"),
         ("💻", "opencode", "終端機裡的 AI 助手：讀寫專案檔案、執行指令、寫程式、查資料、寫作業。",
          "每台電腦都可以裝"),
         ("💬", "Discord bot", "在 Discord 問答、上網查詢，並產生 PPT / Word / Excel 草稿檔案。",
          "跑在筆電 · 自動跟著 vLLM")]
cw = (CW - Inches(0.5)) / 3
for i, (ic, t, d, foot) in enumerate(comps):
    x = MX + (cw + Inches(0.25)) * i
    box(s, x, TOP, cw, Inches(3.4))
    badge(s, x + Inches(0.35), TOP + Inches(0.35), Inches(0.7), ic, fill=TINT, size=20)
    text(s, x + Inches(0.35), TOP + Inches(1.25), cw - Inches(0.7), Inches(0.5), t, size=22, color=INK, bold=True)
    text(s, x + Inches(0.35), TOP + Inches(1.8), cw - Inches(0.7), Inches(1.0), d, size=15, color=BODY, line=1.15)
    text(s, x + Inches(0.35), TOP + Inches(2.85), cw - Inches(0.7), Inches(0.3), foot, size=12, color=BLUE, bold=True)
text(s, MX, TOP + Inches(3.8), CW, Inches(0.5),
     [[("模型、程式碼與對話都留在實驗室，", {"bold": True, "color": INK}),
       ("不經過任何雲端 API。", {"bold": True, "color": BLUE})]], size=17)

# =============================================================================
#  4. 整體架構
# =============================================================================
s = content_slide("01 認識系統", "整體架構",
                  "左邊是筆電：WSL 裡跑 vLLM，筆電本機的 opencode 和 Discord bot 用 127.0.0.1 連它。"
                  "右邊是三種使用者：在實驗室的同學直接用區網 IP；在家的同學先連學校 VPN，之後一樣用區網 IP；"
                  "沒有學校帳號的校外合作者，才用 Tailscale Funnel 的公開 HTTPS 網址。")
# 筆電
lx, ly, lw, lh = MX, TOP, Inches(5.4), Inches(4.6)
box(s, lx, ly, lw, lh, fill=TINT, line=None)
text(s, lx + Inches(0.3), ly + Inches(0.2), lw, Inches(0.4), "Windows 筆電（主機）", size=16, color=INK, bold=True)
box(s, lx + Inches(0.3), ly + Inches(0.75), lw - Inches(0.6), Inches(1.3), fill=CODEBG, line=None)
text(s, lx + Inches(0.55), ly + Inches(0.9), lw - Inches(1.1), Inches(1.1),
     [[("WSL2 Ubuntu", {"color": MUTED, "size": 12})],
      [("vLLM :8000", {"color": WHITE, "bold": True, "size": 20})],
      [("需 API 金鑰 · Qwen3-4B · 32k", {"color": CODETX, "size": 12})]], space=2)
vy = ly + Inches(2.05)
for i, (t, d) in enumerate([("opencode（本機）", "127.0.0.1:8000"), ("Discord bot", "127.0.0.1:8000 · 自動讀金鑰")]):
    bx = lx + Inches(0.3) + (lw - Inches(0.6)) / 2 * i + (Inches(0.1) if i else 0)
    bw = (lw - Inches(0.6)) / 2 - Inches(0.1)
    arrow(s, bx + bw / 2, ly + Inches(2.85), bx + bw / 2, vy + Inches(0.02), color=BLUE)
    box(s, bx, ly + Inches(2.85), bw, Inches(1.05))
    text(s, bx + Inches(0.2), ly + Inches(3.0), bw - Inches(0.4), Inches(0.8),
         [[(t, {"bold": True, "color": INK, "size": 15})], [(d, {"size": 11, "color": BODY})]], space=2)
text(s, lx + Inches(0.3), ly + Inches(4.05), lw - Inches(0.6), Inches(0.4),
     "防火牆 8000：只開放實驗室網段 + 學校 VPN 網段", size=12, color=BODY)
# 使用者
users = [("🏫", "實驗室同學（在校內）", "http://筆電IP:8000/v1", BLUE, False),
         ("🏠", "實驗室同學（在家）", "先連學校 VPN → 同上", BLUE, False),
         ("🌐", "校外合作者（無學校帳號）", "https://筆電.xxx.ts.net/v1（Funnel）", ORANGE, True)]
ux, uw, uh = MX + Inches(7.2), Inches(4.9), Inches(1.25)
for i, (ic, t, d, col, dash) in enumerate(users):
    uy = TOP + Inches(0.15) + (uh + Inches(0.3)) * i
    box(s, ux, uy, uw, uh)
    badge(s, ux + Inches(0.25), uy + Inches(0.3), Inches(0.65), ic, fill=TINT, size=18)
    text(s, ux + Inches(1.1), uy + Inches(0.22), uw - Inches(1.3), Inches(0.9),
         [[(t, {"bold": True, "color": INK, "size": 15})], [(d, {"size": 12, "color": col, "mono": True})]], space=3)
    arrow(s, ux - Inches(0.05), uy + uh / 2, lx + lw + Inches(0.05), ly + Inches(1.4), color=col, dash=dash)
text(s, ux, TOP + Inches(4.7), uw, Inches(0.3), "opencode 只需要「網址 + API 金鑰」", size=12, color=MUTED)

# =============================================================================
#  5. 模型實測
# =============================================================================
s = content_slide("01 認識系統 · 實驗室筆電 RTX 5070 Ti 12GB 實測", "預設模型：Qwen3-4B，32k 上下文",
                  "我們實測過 4B 和 8B。8B 沒有比較好：寫程式驗證錯了一半，長文件慢一倍，能同時服務的人也比較少。"
                  "所以預設用 4B（2507 新版），上下文開到 32k，因為 opencode 每次請求光系統提示就要約 1 萬 token。")
stats = [("27.5", "tok/s", "單人生成速度"), ("121", "tok/s", "五人同時總吞吐"), ("32k", "tokens", "單一對話上下文")]
sw = (CW - Inches(0.5)) / 3
for i, (n, u, d) in enumerate(stats):
    x = MX + (sw + Inches(0.25)) * i
    box(s, x, TOP, sw, Inches(1.75))
    text(s, x + Inches(0.35), TOP + Inches(0.2), sw, Inches(0.9),
         [[(n, {"size": 48, "bold": True, "color": BLUE}), ("  " + u, {"size": 16, "color": BODY})]], space=0)
    text(s, x + Inches(0.35), TOP + Inches(1.15), sw, Inches(0.4), d, size=14, color=INK, bold=True)
table(s, MX, TOP + Inches(2.1), CW, [
    ["測試", "4B · 16k", "4B · 32k（預設）", "8B-AWQ · 32k"],
    ["長文件 2.1 萬 token", "❌ 超過上限", "✅ 9.6 秒", "✅ 17.2 秒"],
    ["五人同時（總吞吐 / 最慢等待）", "61 tok/s / 6.7 秒", "121 tok/s / 3.4 秒", "98 tok/s / 4.1 秒"],
    ["寫程式（執行驗證 6 個案例）", "—", "✅ 6 / 6", "❌ 3 / 6"],
], [3.2, 2.2, 2.4, 2.2], size=14, rowh=0.5)
text(s, MX, TOP + Inches(4.35), CW, Inches(0.35),
     "8GB 顯卡請用 small 組合（4B · 16k）；換模型方式見第 06 段。", size=13, color=MUTED)

# =============================================================================
#  6. 開始前的準備
# =============================================================================
s = content_slide("02 筆電主機安裝", "開始前的準備",
                  "主機只需要一台有 NVIDIA 顯卡的 Windows 11 筆電。最容易忽略的是網路：筆電要接實驗室網路，"
                  "不能接手機熱點，而且最好請網管固定 IP，不然 IP 一變，所有人都要重設。")
reqs = [("🪟", "Windows 11 22H2 以上", "WSL mirrored 網路需要"),
        ("🎮", "NVIDIA 顯卡 8GB 以上", "裝最新版驅動；不要在 WSL 裡另裝"),
        ("💾", "硬碟約 30GB", "WSL、vLLM 約 8GB、模型 4~6GB"),
        ("🔐", "系統管理員權限", "只有安裝時需要"),
        ("🌐", "接實驗室網路、固定 IP", "不要用手機熱點（172.20.10.x）"),
        ("🔌", "插電使用", "腳本會設定插電時不睡眠")]
cw, ch = (CW - Inches(0.5)) / 3, Inches(2.05)
for i, (ic, t, d) in enumerate(reqs):
    x = MX + (cw + Inches(0.25)) * (i % 3)
    y = TOP + (ch + Inches(0.25)) * (i // 3)
    box(s, x, y, cw, ch)
    badge(s, x + Inches(0.3), y + Inches(0.3), Inches(0.6), ic, fill=TINT, size=16)
    text(s, x + Inches(0.3), y + Inches(1.05), cw - Inches(0.6), Inches(0.45), t, size=17, color=INK, bold=True)
    text(s, x + Inches(0.3), y + Inches(1.5), cw - Inches(0.6), Inches(0.45), d, size=13, color=BODY)

# =============================================================================
#  7. 一鍵安裝
# =============================================================================
s = content_slide("02 筆電主機安裝 · 全程約 20~40 分鐘，下載約 15GB", "雙擊 setup-host.cmd 完成安裝",
                  "整個安裝只要雙擊一個檔案。第一次如果還沒有 WSL，腳本會先安裝 Ubuntu 並要求重開機，"
                  "重開機後從開始選單開 Ubuntu 設定帳號密碼，再雙擊一次就會繼續。結束時會印出要給同學的網址和金鑰。")
steps = ["把專案資料夾放到筆電（git clone 或複製）",
         "雙擊 opencode\\host\\setup-host.cmd，同意系統管理員權限",
         "第一次沒有 WSL：自動安裝 → 重開機 → 開「Ubuntu」設定帳密 → 再雙擊一次",
         "出現 [sudo] password 時輸入 Ubuntu 密碼（打字不會顯示）",
         "結束時記下印出的「網址」與「API 金鑰」"]
for i, st in enumerate(steps):
    y = TOP + Inches(0.92) * i
    badge(s, MX, y + Inches(0.05), Inches(0.5), str(i + 1), size=14)
    text(s, MX + Inches(0.7), y + Inches(0.1), Inches(6.0), Inches(0.8), st, size=16, color=INK)
code(s, MX + Inches(7.2), TOP, CW - Inches(7.2), Inches(4.6), [
    "# 常用參數：setup-host.cmd -參數",
    "",
    ">-Preset small|laptop|quality",
    "# 模型組合；預設依顯存自動選",
    "",
    ">-AllowFrom LocalSubnet,<VPN網段>",
    "# 防火牆開放來源（見第 05 段）",
    "",
    ">-SkipVllm",
    "# 只重做 Windows 端：防火牆、電源、opencode",
    "",
    ">-EnableSsh",
    "# 開 OpenSSH，讓人 ssh 進來用",
], size=13)

# =============================================================================
#  8. setup-host 做的事
# =============================================================================
s = content_slide("02 筆電主機安裝", "setup-host.cmd 自動完成的事",
                  "這八件事都是自動的，而且可以重複執行：再跑一次只會更新，不會蓋掉你改過的設定。"
                  "RTX 50 系列顯卡的相容設定也會自動處理，不需要另外裝 CUDA Toolkit。")
todo = ["檢查 NVIDIA 驅動、Windows 版本",
        "偵測 / 安裝 WSL2 Ubuntu",
        "WSL 改 mirrored 網路，和筆電共用 IP",
        "排程 vLLM-WSL-KeepAlive：登入後讓 WSL 常駐",
        "在 WSL 裝 vLLM、依顯存選模型、產生 API 金鑰",
        "防火牆開放 TCP 8000（預設只允許同網段）",
        "電源：插電時不睡眠、闔上螢幕不動作",
        "安裝 opencode，連到本機 vLLM"]
cw, rh = (CW - Inches(0.3)) / 2, Inches(0.95)
for i, t in enumerate(todo):
    col, row = i // 4, i % 4
    x, y = MX + (cw + Inches(0.3)) * col, TOP + (rh + Inches(0.15)) * row
    box(s, x, y, cw, rh)
    badge(s, x + Inches(0.25), y + Inches(0.2), Inches(0.55), str(i + 1), size=14)
    text(s, x + Inches(1.0), y, cw - Inches(1.2), rh, t, size=16, color=INK, anchor=MSO_ANCHOR.MIDDLE, space=0)

# =============================================================================
#  9. 同學電腦安裝 opencode
# =============================================================================
s = content_slide("03 同學使用 opencode", "同學的電腦：雙擊 install-client.cmd",
                  "同學的電腦不需要顯卡。安裝程式會先測試能不能連到筆電，連不到會直接說原因，"
                  "常見是筆電休眠、IP 打錯或不在同一個網路。裝完一定要開新的終端機，PATH 才會生效。")
steps = ["向管理者拿「網址」和「API 金鑰」（筆電 vllmctl.cmd 輸入 info）",
         "複製專案的 opencode\\client 資料夾到自己電腦",
         "雙擊 install-client.cmd，貼上網址與金鑰",
         "開一個新的終端機，cd 到專案資料夾，輸入 opencode"]
for i, st in enumerate(steps):
    y = TOP + Inches(1.0) * i
    badge(s, MX, y + Inches(0.05), Inches(0.5), str(i + 1), size=14)
    text(s, MX + Inches(0.7), y + Inches(0.1), Inches(6.0), Inches(0.8), st, size=16, color=INK)
code(s, MX + Inches(7.2), TOP, CW - Inches(7.2), Inches(2.6), [
    "# 網址範例（結尾要有 /v1）",
    ">http://192.168.1.23:8000/v1",
    "",
    "# 腳本自動完成",
    "1. 測試連線  2. 用 Scoop 裝 opencode",
    "3. 寫入 opencode.json  4. 裝共用規則",
], size=13)
box(s, MX + Inches(7.2), TOP + Inches(2.85), CW - Inches(7.2), Inches(1.75))
text(s, MX + Inches(7.5), TOP + Inches(3.05), CW - Inches(7.8), Inches(1.5),
     [[("Ubuntu 電腦", {"bold": True, "color": INK, "size": 15})],
      [("bash client/install-client.sh --url <網址> --key <金鑰> --name laptop", {"mono": True, "size": 12})],
      [("桌面版：opencode.ai/download 下載，再用 -SkipInstall 跑一次", {"size": 12})]], space=6)

# =============================================================================
#  10. 第一次開啟 opencode
# =============================================================================
s = content_slide("03 同學使用 opencode", "第一次開啟 opencode",
                  "opencode 只會讀寫目前資料夾底下的檔案，所以要先 cd 到專案資料夾再啟動。"
                  "第一次進專案先打 /init，它會產生 AGENTS.md 記錄專案結構，小模型有了它表現好很多。")
code(s, MX, TOP, Inches(5.6), Inches(4.4), [
    "# 開新的終端機",
    "cd C:\\Users\\你\\Documents\\my-thesis",
    ">opencode",
    "",
    "# 第一次進這個專案",
    ">/init",
    "",
    "# 確認用的是筆電的模型",
    "/models",
], size=15)
tips = [("下方輸入框", "用中文描述需求，Enter 送出"),
        ("畫面下方顯示 laptop/qwen3-4b", "代表正在用筆電的 vLLM"),
        ("Tab 鍵", "切換 Build（會改檔）／ Plan（只分析不改）"),
        ("/init", "產生 AGENTS.md，之後每次對話都會參考")]
rx = MX + Inches(6.0)
for i, (t, d) in enumerate(tips):
    y = TOP + Inches(1.12) * i
    box(s, rx, y, CW - Inches(6.0), Inches(0.95))
    text(s, rx + Inches(0.3), y + Inches(0.12), CW - Inches(6.6), Inches(0.75),
         [[(t, {"bold": True, "color": INK, "size": 15})], [(d, {"size": 13})]], space=2)

# =============================================================================
#  11. 常用指令
# =============================================================================
s = content_slide("03 同學使用 opencode", "常用指令",
                  "打斜線會跳出完整的指令清單。最常用的是 /models、/compact 和 /undo。"
                  "@ 後面接檔名可以直接指定檔案，模型不用自己找，也比較省上下文。")
table(s, MX, TOP, CW, [
    ["輸入", "作用"],
    ["直接打字 + Enter", "用中文描述需求（回答會是繁體中文）"],
    ["@檔名", "指定檔案，例：@src/train.py"],
    ["Tab", "切換 Build（會改檔）／ Plan（只分析不改）"],
    ["/init", "分析專案、產生 AGENTS.md"],
    ["/models", "切換模型"],
    ["/undo · /redo", "復原 / 重做上一次修改"],
    ["/new · /compact", "開新對話 / 壓縮過長的對話（超過上下文時用）"],
    ["/exit 或 Ctrl+C", "離開"],
], [3, 7], size=15, rowh=0.5, mono_cols=(0,))

# =============================================================================
#  12. 提問技巧
# =============================================================================
s = content_slide("03 同學使用 opencode", "讓小模型也好用的提問技巧",
                  "4B 小模型可以做事，但要給明確、範圍小的任務。好的提問包含三件事：哪個檔案、哪個函式、要達到什麼結果。")
tips = [("1", "一次只做一件事", "「在 utils.py 加一個讀 CSV 的函式」比「重構整個專案」可靠得多。"),
        ("2", "直接指名檔案", "用 @src/train.py 指定檔案，寫出相對路徑，避免寫到 C:\\。"),
        ("3", "先 Plan 再 Build", "Tab 切到 Plan 讓它先列步驟，確認方向正確再切回 Build。"),
        ("4", "對話變長就重來", "回應變慢或出錯時用 /compact 或 /new；用中文問，回答就是中文。")]
cw, ch = (CW - Inches(0.3)) / 2, Inches(1.55)
for i, (n, t, d) in enumerate(tips):
    x, y = MX + (cw + Inches(0.3)) * (i % 2), TOP + (ch + Inches(0.25)) * (i // 2)
    box(s, x, y, cw, ch)
    badge(s, x + Inches(0.3), y + Inches(0.3), Inches(0.55), n, size=15)
    text(s, x + Inches(1.1), y + Inches(0.28), cw - Inches(1.4), Inches(1.1),
         [[(t, {"bold": True, "color": INK, "size": 17})], [(d, {"size": 14})]], space=4, line=1.1)
code(s, MX, TOP + Inches(3.65), CW, Inches(0.95), [
    "# 範例",
    "@data/loader.py 的 load_csv 讀到空白列會出錯，請修正並加上單元測試",
], size=14)

# =============================================================================
#  13. Discord bot 安裝
# =============================================================================
s = content_slide("04 Discord bot", "Discord bot：接同一台 vLLM",
                  "Discord bot 不另外架模型，直接用 opencode 的 vLLM。它會自動讀 WSL 裡的金鑰，"
                  "也會自動問 vLLM 目前是哪個模型，所以之後換模型、換金鑰，bot 都不用改設定。")
steps = ["先完成 02 的主機安裝（vLLM 要在跑）",
         "在專案根目錄執行 deploy.ps1：建環境、自動填好 .env",
         "Discord Developer Portal 建 bot，打開 MESSAGE CONTENT INTENT",
         "邀請 bot 時權限要勾 Attach Files，token 填進 .env",
         "測試：雙擊 start-bot.bat；正式：系統管理員執行 install-autostart.ps1"]
for i, st in enumerate(steps):
    y = TOP + Inches(0.92) * i
    badge(s, MX, y + Inches(0.05), Inches(0.5), str(i + 1), size=14)
    text(s, MX + Inches(0.7), y + Inches(0.1), Inches(6.2), Inches(0.8), st, size=16, color=INK)
code(s, MX + Inches(7.3), TOP, CW - Inches(7.3), Inches(2.3), [
    "# 專案根目錄",
    ">powershell -ExecutionPolicy Bypass",
    ">  -File .\\deploy.ps1",
    "",
    "# .env 只需要手動填這一行",
    "DISCORD_BOT_TOKEN=...",
], size=13)
for i, (t, d) in enumerate([("金鑰", "LLM_API_KEY 留空 → 自動從 WSL 讀，換金鑰也會自動重讀"),
                            ("模型", "自動用 vLLM 目前的模型，Discord 輸入 !model 可確認")]):
    y = TOP + Inches(2.5) + Inches(1.1) * i
    box(s, MX + Inches(7.3), y, CW - Inches(7.3), Inches(0.95))
    text(s, MX + Inches(7.6), y + Inches(0.12), CW - Inches(7.9), Inches(0.75),
         [[(t, {"bold": True, "color": INK, "size": 15})], [(d, {"size": 13})]], space=2)

# =============================================================================
#  14. Discord 指令
# =============================================================================
s = content_slide("04 Discord bot", "Discord 指令",
                  "產檔指令可以附上 txt、md、docx、pdf，或用 Discord 的「回覆」功能回覆某則訊息，模型會以那些內容為準。"
                  "例如回覆一則會議記錄，輸入 !ppt 整理成組會報告。產出的都是草稿，文獻一律標為待補，模型被要求不可以捏造。")
table(s, MX, TOP, Inches(7.4), [
    ["指令", "作用"],
    ["@bot / 私訊 / 直接發言", "一般問答"],
    ["!web <問題>", "上網搜尋後回答"],
    ["!ppt <主題>", "簡報 .pptx（含講者備註）"],
    ["!word 計畫 <題目>", "國科會研究計畫草稿 .docx"],
    ["!word 報告 <主題>", "課堂報告 .docx"],
    ["!excel <需求>", "表格 .xlsx（可含公式）"],
    ["!model · !reset · !help", "目前模型 · 清記憶 · 說明"],
], [3.2, 4.2], size=14, rowh=0.5, mono_cols=(0,))
rx, rw = MX + Inches(7.8), CW - Inches(7.8)
box(s, rx, TOP, rw, Inches(2.3))
text(s, rx + Inches(0.3), TOP + Inches(0.25), rw - Inches(0.6), Inches(1.9),
     [[("📎 附參考資料", {"bold": True, "color": INK, "size": 16})],
      [("附上 .txt / .md / .docx / .pdf，或「回覆」某則訊息再下指令，內容會以參考資料為準", {"size": 14})]],
     space=6, line=1.1)
box(s, rx, TOP + Inches(2.5), rw, Inches(1.5))
text(s, rx + Inches(0.3), TOP + Inches(2.7), rw - Inches(0.6), Inches(1.2),
     [[("⚠️ 產出是草稿", {"bold": True, "color": RED, "size": 16})],
      [("文獻標為 [待補]，數據與論述請自行查證", {"size": 14})]], space=6)

# =============================================================================
#  15. 不在實驗室時
# =============================================================================
s = content_slide("05 不在實驗室時", "三種使用者，三種連線方式",
                  "實驗室同學在家時，連上學校 VPN 就等於在校內網路，其他設定完全不用改，也不用裝 Tailscale。"
                  "只有沒有學校帳號、不能用 VPN 的校外合作者，才需要用 Tailscale Funnel，而且用完就關。")
cols = [("🏫", "在實驗室", "實驗室同學", "http://筆電IP:8000/v1", ["區網直連", "什麼都不用多做"], BLUE),
        ("🏠", "在家", "實驗室同學", "先連學校 VPN", ["之後跟在實驗室一樣", "第一次要把 VPN 網段", "加進防火牆"], BLUE),
        ("🌐", "校外合作者", "沒有學校帳號", "https://筆電.xxx.ts.net/v1", ["Tailscale Funnel", "對方不用裝 Tailscale", "用完就 off"], ORANGE)]
cw = (CW - Inches(0.5)) / 3
for i, (ic, t, who, url, pts, col) in enumerate(cols):
    x = MX + (cw + Inches(0.25)) * i
    box(s, x, TOP, cw, Inches(3.75))
    badge(s, x + Inches(0.35), TOP + Inches(0.35), Inches(0.75), ic, fill=TINT, size=22)
    text(s, x + Inches(0.35), TOP + Inches(1.3), cw - Inches(0.7), Inches(0.9),
         [[(t, {"bold": True, "color": INK, "size": 22})], [(who, {"size": 13, "color": MUTED})]], space=2)
    text(s, x + Inches(0.35), TOP + Inches(2.2), cw - Inches(0.7), Inches(0.5), url, size=13, color=col, bold=True, mono=True)
    text(s, x + Inches(0.35), TOP + Inches(2.8), cw - Inches(0.7), Inches(1.4), pts, size=14, color=BODY, space=4)

# =============================================================================
#  16. 在家：學校 VPN
# =============================================================================
s = content_slide("05 不在實驗室時 · 在家", "在家：先連學校 VPN",
                  "第一次需要管理者和一位同學一起做，大約十分鐘。重點是找出 VPN 使用者拿到的網段，加進筆電的防火牆。"
                  "LocalSubnet 一定要保留，不然實驗室裡的同學會被擋。不要用 Any 偷懶，學校常配公開 IP，Any 等於整個網際網路都連得到。")
steps = ["同學在家連上 VPN，ipconfig 看 VPN 網卡的 IP",
         "瀏覽器開 http://筆電IP:8000/v1/models",
         "看到 Unauthorized → 已經通了，跳到第 5 步",
         "一直轉圈 → 問計中 VPN 網段，加進防火牆（右邊指令）",
         "雙擊 install-client.cmd，貼上網址與金鑰"]
for i, st in enumerate(steps):
    y = TOP + Inches(0.92) * i
    badge(s, MX, y + Inches(0.05), Inches(0.5), str(i + 1), size=14)
    text(s, MX + Inches(0.7), y + Inches(0.1), Inches(6.0), Inches(0.8), st, size=16, color=INK)
code(s, MX + Inches(7.0), TOP, CW - Inches(7.0), Inches(2.5), [
    "# 筆電，會要求系統管理員權限",
    ">host\\setup-host.cmd -SkipVllm",
    ">  -AllowFrom LocalSubnet,10.8.0.0/16",
    "",
    "# 10.8.0.0/16 換成學校 VPN 的網段",
    "# 多個網段用逗號接下去",
], size=13)
box(s, MX + Inches(7.0), TOP + Inches(2.7), CW - Inches(7.0), Inches(1.9))
text(s, MX + Inches(7.3), TOP + Inches(2.9), CW - Inches(7.6), Inches(1.6),
     [[("⚠️ 不要用 -AllowFrom Any", {"bold": True, "color": RED, "size": 15})],
      [("學校常配 140.x 公開 IP，Any = 整個網際網路都連得到 8000 port。", {"size": 13})],
      [("還是不通：學校 VPN 可能沒開放連實驗室網段，請計中協助。", {"size": 13})]], space=5, line=1.1)

# =============================================================================
#  17. 校外合作者：Funnel
# =============================================================================
s = content_slide("05 不在實驗室時 · 校外合作者", "校外合作者：Tailscale Funnel",
                  "Funnel 會把 vLLM 公開成一個 HTTPS 網址，對方不用裝任何東西。但這代表全世界都連得到這個網址，"
                  "唯一的保護是 API 金鑰，所以給之前先換金鑰，用完就關。腳本只公開 /v1，因為 vLLM 的金鑰只保護 /v1，"
                  "/metrics 這類路徑不需要金鑰。")
code(s, MX, TOP, Inches(5.6), Inches(4.4), [
    "# 筆電：雙擊 host\\funnel.cmd",
    ">on",
    "# 第一次：自動裝 Tailscale → 登入",
    "# → 瀏覽器按「同意啟用 Funnel」",
    "",
    ">test",
    "# 沒金鑰 401、有金鑰 200、/metrics 404",
    "",
    ">off",
    "# 不用時就關",
], size=14)
rx, rw = MX + Inches(6.0), CW - Inches(6.0)
for i, (ic, t, d) in enumerate([("🔑", "給之前先換金鑰", "vllmctl.cmd new-key；合作結束再換一次"),
                                 ("🛡️", "只公開 /v1", "HTTPS 由 Tailscale 自動處理"),
                                 ("⏱️", "第一次最多等 10 分鐘", "公開 DNS 生效；手機關 Wi-Fi 測，看到 401 即成功"),
                                 ("📉", "Beta 功能、有頻寬限制", "適合少數人臨時用")]):
    y = TOP + Inches(1.12) * i
    box(s, rx, y, rw, Inches(0.95))
    badge(s, rx + Inches(0.2), y + Inches(0.17), Inches(0.6), ic, fill=TINT, size=16)
    text(s, rx + Inches(1.0), y + Inches(0.12), rw - Inches(1.2), Inches(0.75),
         [[(t, {"bold": True, "color": INK, "size": 15})], [(d, {"size": 12})]], space=2)

# =============================================================================
#  18. vllmctl
# =============================================================================
s = content_slide("06 管理與排錯", "日常管理：雙擊 host\\vllmctl.cmd",
                  "vllmctl 只在筆電上用，雙擊後輸入指令。最常用的是 info 和 logs。"
                  "stop 可以暫時釋放顯卡，例如筆電要跑其他 GPU 程式時。")
table(s, MX, TOP, CW, [
    ["指令", "作用"],
    ["info", "給同學的網址、金鑰、安裝方式"],
    ["show", "目前設定（金鑰遮蔽）、GPU 用量、KV cache 容量"],
    ["status · logs", "服務狀態 / 即時紀錄（Ctrl+C 離開）"],
    ["start · stop · restart", "啟動 / 停止（釋放 GPU）/ 重啟"],
    ["presets · preset 名稱", "列出 / 換成內建模型組合"],
    ["model HF模型ID 名稱 上下文 parser", "換成任意 Hugging Face 模型"],
    ["set 參數 值 · edit", "修改 vllm.env 參數並重啟"],
    ["new-key · bench", "產生新金鑰 / 跑標準測試"],
], [4, 6], size=15, rowh=0.5, mono_cols=(0,))

# =============================================================================
#  19. API 金鑰
# =============================================================================
s = content_slide("06 管理與排錯 · 金鑰", "API 金鑰：只有一組，大家共用",
                  "金鑰存在筆電 WSL 的 vllm.env。換金鑰後，Discord bot 會自動重讀，不用動；"
                  "但每台 opencode 都要用新金鑰重跑 install-client，筆電本機的 opencode 可以自動讀金鑰，不用貼。"
                  "Hugging Face token 是另一回事，只有下載需要授權的模型才要。")
for i, (t, cmd, d) in enumerate([("查看", "vllmctl.cmd → info", "要給同學時"),
                                   ("換新", "vllmctl.cmd → new-key", "有人離開、金鑰外流時；舊的立即失效")]):
    x = MX + (Inches(6.0) + Inches(0.3)) * i
    box(s, x, TOP, Inches(6.0), Inches(1.3))
    text(s, x + Inches(0.3), TOP + Inches(0.2), Inches(5.4), Inches(1.0),
         [[(t + "  ", {"bold": True, "color": INK, "size": 18}), (cmd, {"mono": True, "color": BLUE, "size": 15})],
          [(d, {"size": 14})]], space=6)
text(s, MX, TOP + Inches(1.6), CW, Inches(0.4), "換金鑰之後", size=16, color=INK, bold=True)
table(s, MX, TOP + Inches(2.05), CW, [
    ["誰", "要做什麼"],
    ["Discord bot", "✅ 不用動（遇到金鑰錯誤會自動從 WSL 重讀）"],
    ["筆電的 opencode", "install-client.cmd -Url http://127.0.0.1:8000/v1 -SkipInstall（自動讀金鑰）"],
    ["同學的 opencode", "收到新金鑰後，再雙擊一次 install-client.cmd"],
], [2.5, 7.5], size=14, rowh=0.5)
text(s, MX, TOP + Inches(4.25), CW, Inches(0.35),
     "Hugging Face token（hf_ 開頭）只有下載 Llama、Gemma 等需授權模型才需要：vllmctl.cmd → set HF_TOKEN hf_xxx",
     size=12, color=MUTED)

# =============================================================================
#  20. 換模型
# =============================================================================
s = content_slide("06 管理與排錯 · 換模型", "vLLM 換新模型，四個步驟",
                  "vLLM 一次只載入一個模型，換模型就是下載新的再換掉舊的。vllmctl 會先下載完才切換，"
                  "下載期間大家照常使用，切換時中斷約一分鐘。換完一定要跑 bench，再請大家重跑 install-client，"
                  "原本指向舊模型的預設值會自動改成新模型。Discord bot 不用動。")
flow = [("1", "換模型", "vllmctl.cmd\npreset quality\n或 model …"),
        ("2", "確認正常", "vllmctl.cmd\nbench（約 1 分鐘）"),
        ("3", "更新 opencode", "每台重跑\ninstall-client.cmd"),
        ("4", "Discord bot", "不用動\n!model 確認")]
fw = (CW - Inches(0.3) * 3) / 4
for i, (n, t, d) in enumerate(flow):
    x = MX + (fw + Inches(0.3)) * i
    box(s, x, TOP, fw, Inches(1.9))
    badge(s, x + Inches(0.25), TOP + Inches(0.25), Inches(0.5), n, size=14, fill=ORANGE if i == 3 else BLUE)
    text(s, x + Inches(0.9), TOP + Inches(0.28), fw - Inches(1.0), Inches(0.45), t, size=16, color=INK, bold=True)
    text(s, x + Inches(0.25), TOP + Inches(0.9), fw - Inches(0.5), Inches(0.9), d.split("\n"), size=13, space=1)
code(s, MX, TOP + Inches(2.2), Inches(5.6), Inches(2.4), [
    "# 內建組合",
    ">preset quality   # Qwen3-8B",
    ">preset laptop    # 換回 Qwen3-4B",
    "",
    "# 任意 Hugging Face 模型",
    ">model Qwen/Qwen3-8B-AWQ qwen3-8b 32768 hermes",
], size=13)
table(s, MX + Inches(5.9), TOP + Inches(2.2), CW - Inches(5.9), [
    ["欄位", "說明"],
    ["Qwen/Qwen3-8B-AWQ", "Hugging Face 模型 ID"],
    ["qwen3-8b", "opencode 裡顯示的名字"],
    ["32768", "上下文；opencode 至少 16384"],
    ["hermes", "Qwen 用 hermes；Coder 用 qwen3_coder"],
], [2.3, 3.4], size=13, rowh=0.46, mono_cols=(0,))

# =============================================================================
#  21. 安全性
# =============================================================================
s = content_slide("06 管理與排錯 · 安全性", "四層保護",
                  "校內使用時，API 金鑰加防火牆網段限制已經足夠。開 Funnel 時，全世界都連得到網址，"
                  "所以只公開 /v1、用 HTTPS，並且給校外的人之前先換金鑰，用完就關。")
layers = [("🔑", "API 金鑰", "每個請求都要帶 Authorization: Bearer 金鑰；外流就 new-key。"),
          ("🧱", "防火牆網段", "8000 只開給實驗室網段 + 學校 VPN 網段，不用 Any。"),
          ("🛡️", "Funnel 只公開 /v1", "vLLM 金鑰只保護 /v1；HTTPS 由 Tailscale 自動處理。"),
          ("🔒", "資料留在實驗室", "模型、程式碼、對話都不經過雲端 API。")]
cw, ch = (CW - Inches(0.3)) / 2, Inches(2.0)
for i, (ic, t, d) in enumerate(layers):
    x, y = MX + (cw + Inches(0.3)) * (i % 2), TOP + (ch + Inches(0.3)) * (i // 2)
    box(s, x, y, cw, ch)
    badge(s, x + Inches(0.35), y + Inches(0.35), Inches(0.7), ic, fill=TINT, size=20)
    text(s, x + Inches(1.35), y + Inches(0.35), cw - Inches(1.7), Inches(1.4),
         [[(t, {"bold": True, "color": INK, "size": 19})], [(d, {"size": 15})]], space=6, line=1.1)

# =============================================================================
#  22. 疑難排解
# =============================================================================
s = content_slide("06 管理與排錯 · 任何問題先看 vllmctl.cmd → logs", "疑難排解",
                  "最常見的是顯存不足和連不到。紀錄裡的 Engine core initialization failed 只是總結，"
                  "往上找第一個 RuntimeError 才是真正原因。")
table(s, MX, TOP, CW, [
    ["症狀", "處理"],
    ["opencode：Cannot connect to API", "vllmctl.cmd → status；沒在跑就 start"],
    ["重開機後大家都連不到", "要先登入 Windows；排程 vLLM-WSL-KeepAlive 要在執行中"],
    ["同學連不到、筆電本機可以", "IP 變了？筆電接手機熱點？在家要先連 VPN、網段加進防火牆"],
    ["啟動失敗、顯存不足（OOM）", "vllmctl.cmd → set SERVE_MAX_LEN 16384 或 set SERVE_GPU_UTIL 0.80"],
    ["opencode 報超過 context 上限", "/compact 或 /new；常發生就加大 SERVE_MAX_LEN"],
    ["Discord：連不上 vLLM / 金鑰錯誤", "vllmctl.cmd → status；.env 的 LLM_API_KEY 清空後重啟 bot"],
    ["輸入 opencode 找不到指令", "開一個新的終端機視窗"],
], [3.8, 6.2], size=14, rowh=0.52)

# =============================================================================
#  23. 指令小抄
# =============================================================================
s = new_slide(dark=True)
header(s, "總結", "指令小抄", dark=True)
footer(s, dark=True)
notes(s, "最後這頁可以截圖貼在實驗室群組。完整步驟寫在 repo 根目錄的「完整步驟.md」。")
cols = [("安裝", [("筆電主機（opencode\\host）", "setup-host.cmd"),
                  ("同學電腦（opencode\\client）", "install-client.cmd"),
                  ("Discord bot", "deploy.ps1 → start-bot.bat")]),
        ("使用", [("在專案資料夾", "opencode"),
                  ("opencode 裡", "/init  /models  /compact  /undo"),
                  ("Discord", "!ppt  !word  !excel  !web")]),
        ("管理（vllmctl.cmd）", [("連線資訊 / 紀錄", "info · logs"),
                                ("換模型", "preset quality · bench"),
                                ("換金鑰 / 校外", "new-key · funnel.cmd on|off")])]
cw = (CW - Inches(0.5)) / 3
for i, (t, rows) in enumerate(cols):
    x = MX + (cw + Inches(0.25)) * i
    box(s, x, TOP, cw, Inches(4.6), fill=NAVY2, line=None)
    text(s, x + Inches(0.35), TOP + Inches(0.3), cw - Inches(0.7), Inches(0.5), t, size=20, color=ORANGE, bold=True)
    for j, (lab, cmd) in enumerate(rows):
        y = TOP + Inches(1.05) + Inches(1.15) * j
        text(s, x + Inches(0.35), y, cw - Inches(0.7), Inches(1.0),
             [[(lab, {"size": 13, "color": MUTED})], [(cmd, {"size": 14, "color": WHITE, "mono": True})]], space=4)

prs.save(OUT)
print(OUT, len(prs.slides), "頁")
