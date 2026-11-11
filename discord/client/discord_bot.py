"""
discord_bot.py — 把實驗室主機上的 vLLM（opencode 共用的那台）接到 Discord。
可以跑在 Windows 筆電（deploy.ps1，vLLM 在 WSL）或 Ubuntu 伺服器（deploy.sh，systemd 服務 discord-bot）。

指令：
    (直接聊天)                在允許的頻道發訊息、@提及 bot、或私訊 → 問答；模型會自己決定要不要用工具
                              （搜尋、讀網頁、維基、arXiv、計算、時間、長期記憶… 見 mcp_servers.json）
    !web <問題>               強制先上網搜尋再回答
    !tools                    列出目前可用的工具 / MCP server 狀態
    !ppt <主題/需求>          產生 PowerPoint (.pptx)
    !word [計畫|報告] <需求>  產生 Word (.docx)；計畫=國科會計畫格式、報告=課堂報告
    !excel <需求>             產生 Excel (.xlsx)
    !models                   列出模型服務上可用的模型
    !model [名稱|auto]        不加參數=顯示目前；加名稱=切換模型（本次執行有效）；auto=回預設
    !reset                    清空這個頻道的對話記憶
    !help                     顯示說明

產檔指令可附加 .txt / .md / .docx / .pdf 檔，或「回覆」某則訊息，當作參考資料。
設定都在同目錄的 .env（見 .env.example）。
"""

import asyncio
import functools
import io
import os
import time
from datetime import datetime, timedelta, timezone

import discord
import requests
from dotenv import load_dotenv

# 先讀 .env，llm_client / office_gen 在 import 時會讀環境變數
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(BASE_DIR, ".env"), override=True)

import agent  # noqa: E402
import llm_client  # noqa: E402
import mcp_client  # noqa: E402
import office_gen  # noqa: E402
import skills  # noqa: E402
import slides_agent  # noqa: E402
import slides_sandbox  # noqa: E402

# --- 讀設定 -----------------------------------------------------------------
TOKEN          = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
SYSTEM_PROMPT  = os.getenv("SYSTEM_PROMPT", "你是研究室的 AI 助理，請用台灣繁體中文回答。")
MAX_HISTORY    = int(os.getenv("MAX_HISTORY", "10"))
# 記憶的總字數上限（vLLM 的上下文和 opencode 的同學共用，別塞太多）
HISTORY_CHARS  = int(os.getenv("HISTORY_MAX_CHARS", "8000"))
# 附件 / 回覆訊息當參考資料時，最多讀幾個字
REF_MAX_CHARS  = int(os.getenv("REF_MAX_CHARS", "10000"))
TO_TRADITIONAL = os.getenv("TO_TRADITIONAL", "1").strip() not in ("0", "false", "False", "")
_allowed       = os.getenv("ALLOWED_CHANNEL_ID", "").strip()
ALLOWED_CHANNEL_ID = int(_allowed) if _allowed.isdigit() else None

SEARCH_ENGINE  = os.getenv("SEARCH_ENGINE", "google").strip().lower()
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "").strip()
GOOGLE_CSE_ID  = os.getenv("GOOGLE_CSE_ID", "").strip()
# 讓模型自己呼叫工具（內建 web_search + mcp_servers.json 的 MCP server）
ENABLE_TOOLS   = os.getenv("ENABLE_TOOLS", "1").strip() not in ("0", "false", "False", "")
# 用工具時的進度顯示：brief = 一則「查資料中…」訊息、答完自動刪掉；off = 不顯示
TOOL_STATUS    = os.getenv("TOOL_STATUS", "brief").strip().lower()
# !ppt：code = 模型寫 python-pptx 程式、在 LXD 沙盒執行並看預覽修正；json = 舊的固定版面
PPT_MODE       = os.getenv("PPT_MODE", "code").strip().lower()
TW_TZ          = timezone(timedelta(hours=8))


if not TOKEN or TOKEN.startswith("貼上"):
    raise SystemExit("請先在 .env 填入 DISCORD_BOT_TOKEN")

# --- 簡轉繁（Qwen 偶爾會冒出簡體字）----------------------------------------
_cc = None
if TO_TRADITIONAL:
    try:
        from opencc import OpenCC
        _cc = OpenCC("s2tw")   # 簡體 → 台灣繁體字形（不轉用語，避免「研究程序」被改成「研究程式」）
    except Exception as e:  # noqa: BLE001
        print(f"[警告] OpenCC 載入失敗，不做簡轉繁：{e}")


def tw(text: str) -> str:
    return _cc.convert(text) if (_cc and text) else text


def tw_obj(obj):
    """把 JSON 裡所有字串都轉成繁體。"""
    if isinstance(obj, str):
        return tw(obj)
    if isinstance(obj, list):
        return [tw_obj(x) for x in obj]
    if isinstance(obj, dict):
        return {k: tw_obj(v) for k, v in obj.items()}
    return obj


# --- 對話記憶（以頻道為單位）------------------------------------------------
histories: dict[int, list[dict]] = {}


def _trim(msgs: list[dict]) -> list[dict]:
    """保留最近 MAX_HISTORY 則，且總字數不超過 HISTORY_CHARS。"""
    msgs = msgs[-MAX_HISTORY:]
    while len(msgs) > 1 and sum(len(m["content"]) for m in msgs) > HISTORY_CHARS:
        msgs = msgs[1:]
    # 開頭必須是 user，否則部分模型的 chat template 會報錯
    while msgs and msgs[0]["role"] != "user":
        msgs = msgs[1:]
    return msgs


# --- 聯網搜尋 ---------------------------------------------------------------
def _google_search(query: str, n: int = 5) -> str:
    """Google Custom Search JSON API（官方，免費 100 次/天）。"""
    resp = requests.get(
        "https://www.googleapis.com/customsearch/v1",
        params={
            "key": GOOGLE_API_KEY,
            "cx": GOOGLE_CSE_ID,
            "q": query,
            "num": min(n, 10),
            "hl": "zh-TW",
        },
        timeout=20,
    )
    resp.raise_for_status()
    items = resp.json().get("items", [])
    lines = []
    for i, it in enumerate(items[:n], 1):
        lines.append(f"[{i}] {it.get('title','')}\n{it.get('snippet','')}\n來源：{it.get('link','')}")
    return "\n\n".join(lines) if lines else "（查無結果）"


def _ddg_search(query: str, n: int = 5) -> str:
    """DuckDuckGo 搜尋（免申請，作為備援）。"""
    try:
        from ddgs import DDGS
    except ImportError:  # 舊版套件名
        from duckduckgo_search import DDGS  # type: ignore
    lines = []
    with DDGS() as ddgs:
        for i, r in enumerate(ddgs.text(query, max_results=n), 1):
            lines.append(f"[{i}] {r.get('title','')}\n{r.get('body','')}\n來源：{r.get('href','')}")
    return "\n\n".join(lines) if lines else "（查無結果）"


def web_search(query: str, n: int = 5) -> str:
    """依設定選搜尋引擎；Google 沒設金鑰時自動退回 DuckDuckGo。"""
    use_google = SEARCH_ENGINE == "google" and GOOGLE_API_KEY and GOOGLE_CSE_ID
    if use_google:
        try:
            return _google_search(query, n)
        except Exception as e:  # Google 失敗（如超額）時退回 DDG
            return _ddg_search(query, n) + f"\n\n（註：Google 搜尋失敗改用備援：{e}）"
    return _ddg_search(query, n)


# --- 工具（給模型呼叫）------------------------------------------------------
_WMO = {0: "晴", 1: "大致晴", 2: "多雲", 3: "陰", 45: "霧", 48: "霧淞", 51: "毛毛雨", 53: "毛毛雨", 55: "毛毛雨",
        61: "小雨", 63: "中雨", 65: "大雨", 66: "凍雨", 67: "凍雨", 71: "小雪", 73: "中雪", 75: "大雪",
        80: "陣雨", 81: "陣雨", 82: "強陣雨", 95: "雷雨", 96: "雷雨伴冰雹", 99: "雷雨伴冰雹"}


def get_weather(location: str, days: int = 3) -> str:
    """Open-Meteo（免費、免金鑰）：先地名轉經緯度，再查目前天氣與每日預報。"""
    days = max(1, min(int(days), 7))
    g = requests.get("https://geocoding-api.open-meteo.com/v1/search",
                     params={"name": location, "count": 1, "language": "zh"}, timeout=15)
    g.raise_for_status()
    hits = g.json().get("results") or []
    if not hits:
        return f"找不到地點「{location}」，請改用英文地名（例如 Hsinchu）再試"
    p = hits[0]
    f = requests.get("https://api.open-meteo.com/v1/forecast", params={
        "latitude": p["latitude"], "longitude": p["longitude"], "timezone": "auto", "forecast_days": days,
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max",
    }, timeout=15)
    f.raise_for_status()
    d = f.json()
    c, dl = d["current"], d["daily"]
    place = "、".join(x for x in (p.get("name"), p.get("admin1"), p.get("country")) if x)
    lines = [f"地點：{place}（資料：Open-Meteo，https://open-meteo.com）",
             f"現在（{c['time']}）：{_WMO.get(c['weather_code'], c['weather_code'])}，{c['temperature_2m']}°C"
             f"（體感 {c['apparent_temperature']}°C），濕度 {c['relative_humidity_2m']}%，風速 {c['wind_speed_10m']} km/h"]
    for i, day in enumerate(dl["time"]):
        lines.append(f"{day}：{_WMO.get(dl['weather_code'][i], dl['weather_code'][i])}，"
                     f"{dl['temperature_2m_min'][i]}~{dl['temperature_2m_max'][i]}°C，"
                     f"降雨機率 {dl['precipitation_probability_max'][i]}%，最大風速 {dl['wind_speed_10m_max'][i]} km/h")
    return "\n".join(lines)


BUILTIN_TOOLS: agent.Builtin = {
    "get_weather": (
        {"type": "function", "function": {
            "name": "get_weather",
            "description": "查某地目前天氣與未來幾天預報（溫度、降雨機率、風速）。使用者問天氣時直接用這個，一次就夠，不必再搜尋網頁。",
            "parameters": {"type": "object", "properties": {
                "location": {"type": "string", "description": "城市名，英文較準，例如 Hsinchu、Taipei、Tokyo"},
                "days": {"type": "integer", "description": "預報天數 1~7，預設 3"},
            }, "required": ["location"]},
        }},
        get_weather,
    ),
    "web_search": (
        {"type": "function", "function": {
            "name": "web_search",
            "description": "上網搜尋，回傳前幾筆結果的標題、摘要與網址。需要最新資訊、新聞、查證事實時使用；"
                           "要看某個結果的全文，再用讀網頁的工具（fetch）。",
            "parameters": {"type": "object", "properties": {
                "query": {"type": "string", "description": "搜尋關鍵字"},
                "n": {"type": "integer", "description": "要幾筆結果（1~10，預設 5）"},
            }, "required": ["query"]},
        }},
        lambda query, n=5: web_search(query, max(1, min(int(n), 10))),
    ),
}

mcp = mcp_client.MCPManager()
_WEEK = "一二三四五六日"


def system_prompt() -> str:
    now = datetime.now(TW_TZ)
    s = (f"{SYSTEM_PROMPT}\n\n現在時間：{now:%Y-%m-%d} 星期{_WEEK[now.weekday()]} {now:%H:%M}（台灣時間）。"
         "你在 Discord 上回覆，可以用 Markdown，但不要用表格（Discord 不支援）。")
    if ENABLE_TOOLS and agent.tools_supported():
        s += ("\n你可以呼叫工具。遇到需要最新資訊、查證事實、使用者貼了網址、論文、精確計算時，先用工具再回答，"
              "並在回答附上資料來源網址；能直接回答的簡單問題就不要用工具。不要捏造工具沒查到的內容。"
              "用最少的工具呼叫拿到答案：資料夠了就回答，不要為了更精確反覆搜尋。回答要精簡。")
        s += skills.prompt_section()
    return s


# --- 技能庫：模型可以讀技能、提案新技能（管理員按 ✅ 才生效）---------------
APPROVE, REJECT = "✅", "❌"
# 等待核准的提案：Discord 訊息 ID → {name, description, content, proposer}（存在記憶體，bot 重啟就失效）
pending_skills: dict[int, dict] = {}


def skill_tools(proposals: list[dict], proposer: str) -> agent.Builtin:
    """每次對話一份：propose_skill 只先收集起來，回答送出後再貼到頻道請管理員核准。"""
    def read_skill(name: str) -> str:
        sk = skills.get_skill(name)
        return sk[1] if sk else f"沒有名為 {name} 的技能；現有技能：{', '.join(n for n, _ in skills.list_skills()) or '（無）'}"

    def propose_skill(name: str, description: str, content: str) -> str:
        why = skills.validate(name, description, content)
        if why:
            return f"提案不合格：{why}"
        if len(proposals) >= 2:
            return "這次對話已經提案太多了，請先等管理員審核"
        proposals.append({"name": skills.safe_name(name), "description": description.strip(),
                          "content": content.strip(), "proposer": proposer})
        return "已送出提案，管理員按 ✅ 核准後才會生效。請在回答中簡短告訴使用者你提案了什麼技能。"

    return {
        "read_skill": ({"type": "function", "function": {
            "name": "read_skill",
            "description": "讀取技能庫裡某個技能的完整做法。問題和技能清單中的某項相關時先讀。",
            "parameters": {"type": "object", "properties": {
                "name": {"type": "string", "description": "技能名稱（技能清單上的名字）"},
            }, "required": ["name"]},
        }}, read_skill),
        "propose_skill": ({"type": "function", "function": {
            "name": "propose_skill",
            "description": "提案新增技能，或用同名覆蓋來修改既有技能。要 Discord 管理員核准才會生效。"
                           "內容寫成可重複使用的步驟、推薦資料來源與注意事項，精簡為主。",
            "parameters": {"type": "object", "properties": {
                "name": {"type": "string", "description": "技能名稱，簡短英文或中文，例如 pikmin-events"},
                "description": {"type": "string", "description": "一句話：什麼情況下要用這個技能"},
                "content": {"type": "string", "description": "技能內容（Markdown，3000 字以內）"},
            }, "required": ["name", "description", "content"]},
        }}, propose_skill),
    }


def is_admin(member) -> bool:
    perms = getattr(member, "guild_permissions", None)
    return bool(perms and (perms.administrator or perms.manage_guild))


async def post_proposal(channel, p: dict):
    old = skills.get_skill(p["name"])
    head = "✏️ **技能修改提案**" if old else "🧠 **新技能提案**"
    body = p["content"] if len(p["content"]) <= 1400 else p["content"][:1400] + "\n…（完整內容核准後可用 !skill 查看）"
    text = (f"{head}：`{p['name']}`（由 {p['proposer']} 的對話產生）\n"
            f"說明：{p['description']}\n```md\n{body.replace('```', 'ʼʼʼ')}\n```\n"
            f"管理員按 {APPROVE} 核准、{REJECT} 拒絕。")
    msg = await channel.send(text[:2000])
    pending_skills[msg.id] = p
    for emoji in (APPROVE, REJECT):
        await msg.add_reaction(emoji)


# --- 參考資料：附件 / 被回覆的訊息 -----------------------------------------
TEXT_EXT = (".txt", ".md", ".csv")


def _read_attachment(name: str, data: bytes) -> str:
    low = name.lower()
    if low.endswith(TEXT_EXT):
        for enc in ("utf-8-sig", "cp950", "utf-16"):
            try:
                return data.decode(enc)
            except UnicodeDecodeError:
                continue
        return data.decode("utf-8", errors="ignore")
    if low.endswith(".docx"):
        from docx import Document
        doc = Document(io.BytesIO(data))
        return "\n".join(p.text for p in doc.paragraphs if p.text.strip())
    if low.endswith(".pdf"):
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data))
        return "\n".join((pg.extract_text() or "") for pg in reader.pages)
    return ""


async def gather_reference(message: discord.Message) -> tuple[str, list[str]]:
    """回傳（參考文字, 提示訊息）。"""
    parts, notes = [], []
    if message.reference and message.reference.message_id:
        try:
            ref = message.reference.resolved
            if not isinstance(ref, discord.Message):
                ref = await message.channel.fetch_message(message.reference.message_id)
            if ref.content.strip():
                parts.append(ref.content.strip())
        except discord.DiscordException:
            pass
    for att in message.attachments:
        if not att.filename.lower().endswith(TEXT_EXT + (".docx", ".pdf")):
            notes.append(f"略過不支援的附件：{att.filename}")
            continue
        try:
            text = await run_blocking(_read_attachment, att.filename, await att.read())
            if text.strip():
                parts.append(f"【{att.filename}】\n{text.strip()}")
        except Exception as e:  # noqa: BLE001
            notes.append(f"讀取 {att.filename} 失敗：{e}")
    ref_text = "\n\n".join(parts)
    if len(ref_text) > REF_MAX_CHARS:
        notes.append(f"參考資料共 {len(ref_text)} 字，只取前 {REF_MAX_CHARS} 字（受顯卡上下文限制）")
        ref_text = ref_text[:REF_MAX_CHARS]
    return ref_text, notes


# --- 工具 -------------------------------------------------------------------
def chunk_text(text: str, size: int = 1900) -> list[str]:
    if not text:
        return ["（空白回應）"]
    return [text[i:i + size] for i in range(0, len(text), size)]


async def run_blocking(func, *args, **kwargs):
    """在執行緒池跑同步函式，避免卡住事件迴圈。"""
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, functools.partial(func, *args, **kwargs))


def friendly_error(e: Exception) -> str:
    if isinstance(e, requests.exceptions.ConnectionError) and not llm_client.is_local():
        return f"⚠️ 連不上模型服務（{llm_client.BASE_URL}），請稍後再試或請管理者檢查網路 / 金鑰。"
    if isinstance(e, requests.exceptions.ConnectionError):
        return ("⚠️ 連不上 vLLM。請管理者在主機執行 `vllmctl status` 檢查、`vllmctl start` 啟動"
                "（Windows 筆電：雙擊 `server\\wsl2\\vllmctl.cmd`；Ubuntu 伺服器：`bash ~/local-llm/server/vllm/vllmctl.sh`）。")
    if isinstance(e, requests.exceptions.Timeout):
        return "⚠️ 模型回應逾時（可能正在換模型，或很多人同時使用），請稍後再試。"
    if isinstance(e, llm_client.AuthError):
        return ("⚠️ vLLM 拒絕連線（API 金鑰錯誤），bot 重讀主機的金鑰後仍失敗。"
                "若 `.env` 有填 `LLM_API_KEY`，請清空讓 bot 自動讀取，再重啟 bot。")
    if llm_client.is_context_error(e):
        return "⚠️ 內容太長，超過模型的上下文長度。請用 `!reset` 清記憶，或縮短參考資料。"
    return f"⚠️ 發生錯誤：`{str(e)[:300]}`"


HELP_TEXT = """**📖 使用說明**
• 直接聊天：@我、私訊，或在指定頻道發言；我會視需要自己上網搜尋、讀網址、查維基 / arXiv、計算
• `!web <問題>`：強制先上網搜尋再回答
• `!tools`：看目前能用哪些工具
• `!skills`：看我學會的技能；`!skill <名稱>` 看內容（教我做法時說「記成技能」，管理員按 ✅ 才生效）
• `!ppt <主題>`：查資料、設計並自我檢查後產生簡報 .pptx（含講者備註，約 3~10 分鐘）
• `!word 計畫 <題目>`：國科會研究計畫草稿 .docx
• `!word 報告 <主題>`：課堂報告 .docx
• `!word <需求>`：一般文件 .docx
• `!excel <需求>`：Excel 表格 .xlsx（可含公式）
• `!models`：列出可用的模型
• `!model <名稱>`：切換模型（本次執行有效）；`!model` 看目前、`!model auto` 回預設
• `!reset`：清空這個頻道的記憶

💡 產檔指令可以**附上 .txt/.md/.docx/.pdf** 或**回覆某則訊息**，當作參考資料。
⚠️ 本地小模型產出的是**草稿**，數據與文獻請務必自行查證。"""


# --- Discord 事件 -----------------------------------------------------------
intents = discord.Intents.default()
intents.message_content = True


class Bot(discord.Client):
    async def setup_hook(self):
        # MCP server 在背景啟動，bot 不必等它們就緒就能上線
        if ENABLE_TOOLS:
            await mcp.start()

    async def close(self):
        await mcp.stop()
        await super().close()


client = Bot(intents=intents)


@client.event
async def on_ready():
    try:
        m = await run_blocking(llm_client.current_model)
        ctx = f"，上下文 {m['max_model_len']}" if m.get("max_model_len") else ""
        info = f"模型={m['id']}{ctx}"
    except Exception as e:  # noqa: BLE001
        info = f"暫時連不上模型服務：{e}"
    think = "關" if llm_client.disable_thinking() else "開"
    print(f"[已上線] {client.user}  {info}  API={llm_client.BASE_URL}  思考={think}  工具={'開' if ENABLE_TOOLS else '關'}")


async def cmd_tools(channel):
    if not ENABLE_TOOLS:
        await channel.send("🔧 工具已關閉（.env 的 `ENABLE_TOOLS=0`）。")
        return
    if not agent.tools_supported():
        await channel.send("⚠️ 目前的模型服務不支援工具呼叫（tools 參數被拒絕），只能一般聊天。")
        return
    lines = ["**🔧 可用工具**", "✅ `web_search`：內建網路搜尋", "✅ `get_weather`：內建天氣（Open-Meteo）"] \
        + mcp.status_lines()
    n = len(BUILTIN_TOOLS) + len(mcp.openai_tools())
    text = "\n".join(lines) + f"\n\n共 {n} 個工具，模型會自己決定要不要用。設定檔：`mcp_servers.json`"
    for part in chunk_text(text):
        await channel.send(part)


async def cmd_models(channel):
    """列出模型服務上可用的模型。"""
    try:
        models = await run_blocking(llm_client.list_models)
    except Exception as e:  # noqa: BLE001
        await channel.send(friendly_error(e))
        return
    if not models:
        await channel.send("（模型服務沒有回傳任何模型）")
        return
    lines = []
    for m in models:
        ctx = f" — 上下文 {m['max_model_len']}" if m.get("max_model_len") else ""
        lines.append(f"• `{m['id']}`{ctx}")
    text = f"**可用模型**（共 {len(models)} 個）：\n" + "\n".join(lines) + "\n\n用 `!model <名稱>` 切換。"
    for part in chunk_text(text):
        await channel.send(part)


async def cmd_model(channel, arg: str = ""):
    """不加參數=顯示目前；加名稱=切換；auto/reset=取消指定回到 .env 預設。"""
    arg = arg.strip()
    if arg:
        if arg.lower() in ("auto", "reset", "自動", "預設"):
            llm_client.set_model("")
            await channel.send("🔄 已取消指定，改回 .env 的 `LLM_MODEL`／自動選擇。用 `!model` 看目前。")
        else:
            llm_client.set_model(arg)
            await channel.send(
                f"✅ 已切換模型為 `{arg}`（本次執行有效，重啟後回到 .env 的 `LLM_MODEL`）。\n"
                "若名稱打錯，下次回答會出現 404，用 `!models` 查正確名稱。")
        return
    try:
        m = await run_blocking(llm_client.current_model, True)
    except Exception as e:  # noqa: BLE001
        await channel.send(friendly_error(e))
        return
    ctx = f"（上下文 {m['max_model_len']} tokens）" if m.get("max_model_len") else ""
    await channel.send(
        f"🤖 目前模型：`{m['id']}`{ctx}\n"
        "用 `!models` 列出可切換的模型、`!model <名稱>` 切換、`!model auto` 回預設。")


async def cmd_generate(message: discord.Message, kind: str, arg: str):
    """!ppt / !word / !excel 共用流程：取參考資料 → 模型出 JSON → 排版 → 上傳。"""
    channel = message.channel
    mode = "一般"
    if kind == "word":
        for m in ("計畫", "報告"):
            if arg.startswith(m):
                mode, arg = m, arg[len(m):].strip()
                break

    ref_text, notes = await gather_reference(message)
    if not arg and not ref_text:
        usage = {"ppt": "`!ppt 生成式 AI 在教育的應用，10 頁`",
                 "word": "`!word 計畫 以深度學習進行電池健康度預測`",
                 "excel": "`!excel 研究計畫經費預算表，含人事費、耗材、差旅，要有小計與總計`"}[kind]
        await channel.send(f"請告訴我需求，例如：{usage}")
        return
    request = arg or "請根據參考資料製作"

    if kind == "ppt":
        msgs, schema, builder = office_gen.ppt_messages(request, ref_text), office_gen.PPT_SCHEMA, office_gen.build_pptx
    elif kind == "word":
        msgs, schema, builder = office_gen.docx_messages(mode, request, ref_text), office_gen.DOCX_SCHEMA, office_gen.build_docx
    else:
        msgs, schema, builder = office_gen.xlsx_messages(request, ref_text), office_gen.XLSX_SCHEMA, office_gen.build_xlsx

    label = {"ppt": "簡報", "word": f"Word（{mode}）", "excel": "Excel"}[kind]
    status = await channel.send(f"📝 正在產生{label}，約需 1~3 分鐘…" + "".join(f"\n（{n}）" for n in notes))
    t0 = time.time()
    async with channel.typing():
        try:
            data = await run_blocking(llm_client.chat_json, msgs, schema, kind)
            data = tw_obj(data)
            path = await run_blocking(builder, data)
        except Exception as e:  # noqa: BLE001
            await status.edit(content=friendly_error(e))
            return

    if kind == "ppt":
        summary = f"共 {len(data.get('slides', [])) + 1} 頁（含封面），講者備註在每頁下方"
    elif kind == "word":
        summary = f"共 {len(data.get('sections', []))} 個章節"
    else:
        summary = f"共 {len(data.get('sheets', []))} 個工作表"
    await status.edit(content=f"✅ 完成：**{data.get('title', '')}**（{summary}，{time.time() - t0:.0f} 秒）")
    await channel.send(
        content="⚠️ 此為 AI 草稿，內容、數據與文獻請務必查證後再使用。",
        file=discord.File(path, filename=os.path.basename(path)),
    )


async def cmd_chat(message: discord.Message, content: str, do_web: bool):
    channel = message.channel
    hist = histories.setdefault(channel.id, [])
    async with channel.typing():
        try:
            user_content = content
            if do_web:
                results = await run_blocking(web_search, content)
                user_content = (
                    f"參考以下網路搜尋結果回答問題，並在句末標註引用編號 [n]：\n\n"
                    f"{results}\n\n問題：{content}"
                )
            msgs = [{"role": "system", "content": system_prompt()}] + _trim(
                hist + [{"role": "user", "content": user_content}])

            status: list[discord.Message] = []
            count = [0]

            async def on_tool(name: str, brief: str):
                # 只用一則訊息顯示進度（off=不顯示），答案出來後刪掉
                count[0] += 1
                if TOOL_STATUS == "off":
                    return
                label = name.split("__")[-1]
                text = f"🔍 查資料中…（第 {count[0]} 步：{label}）"
                if status:
                    await status[0].edit(content=text)
                else:
                    status.append(await channel.send(text, silent=True))

            proposals: list[dict] = []
            tools = {**BUILTIN_TOOLS, **skill_tools(proposals, message.author.display_name)}
            try:
                answer = tw(await agent.run(msgs, mcp=mcp, builtins=tools,
                                            on_tool=on_tool, use_tools=ENABLE_TOOLS))
            finally:
                for m in status:
                    try:
                        await m.delete()
                    except discord.DiscordException:
                        pass
        except Exception as e:  # noqa: BLE001
            await channel.send(friendly_error(e))
            return

    # 記憶只存原始問題，不存整包搜尋結果，省上下文
    hist.append({"role": "user", "content": content})
    hist.append({"role": "assistant", "content": answer})
    hist[:] = _trim(hist)

    for part in chunk_text(answer):
        await channel.send(part)

    for p in proposals:
        if message.guild is None:
            await channel.send(f"🧠 有一個技能提案 `{p['name']}`，但私訊裡沒有管理員能核准，請到伺服器頻道再教我一次。")
            break
        await post_proposal(channel, p)


async def cmd_slides(message: discord.Message, arg: str):
    """!ppt（code 模式）：模型查資料 → 寫 python-pptx 程式 → 沙盒執行 → 看預覽圖修正 → 上傳。"""
    channel = message.channel
    ref_text, notes = await gather_reference(message)
    if not arg and not ref_text:
        await channel.send("請告訴我需求，例如：`!ppt 生成式 AI 在教育的應用，給大學生聽，10 頁`")
        return
    why = await run_blocking(slides_sandbox.available)
    if why:
        await channel.send(f"（投影片沙盒無法使用：{why}；改用簡易模式）")
        await cmd_generate(message, "ppt", arg)
        return

    status = await channel.send("🎨 開始做投影片（查資料 → 寫程式 → 看預覽修正），約需 3~10 分鐘…"
                                + "".join(f"\n（{n}）" for n in notes))
    state: dict = {}
    proposals: list[dict] = []
    steps = [0]

    async def on_tool(name: str, brief: str):
        steps[0] += 1
        if name in ("run_slides_code", "edit_slides_code"):
            label = f"產生並檢查第 {state.get('runs', 0) + 1} 版投影片"
        else:
            label = name.split("__")[-1] + (f"：{brief}" if brief else "")
        await status.edit(content=f"🎨 做投影片中…（第 {steps[0]} 步）{label}"[:300])

    now = datetime.now(TW_TZ)
    extra = f"\n\n現在時間：{now:%Y-%m-%d}（台灣時間）。" + skills.prompt_section()
    msgs = slides_agent.build_messages(arg or "請根據參考資料製作", ref_text, extra)
    tools = {**BUILTIN_TOOLS, **skill_tools(proposals, message.author.display_name),
             **slides_agent.slide_tools(state)}
    t0 = time.time()
    try:
        async with channel.typing():
            answer = tw(await agent.run(msgs, mcp=mcp, builtins=tools, on_tool=on_tool,
                                        max_rounds=slides_agent.SLIDE_TOOL_ROUNDS,
                                        deadline=t0 + slides_agent.DEADLINE_MIN * 60,
                                        call_limit=slides_agent.RESEARCH_LIMIT,
                                        limit_exempt=slides_agent.CODE_TOOLS))
    except Exception as e:  # noqa: BLE001
        await status.edit(content=friendly_error(e))
        return
    if not state.get("pptx"):
        await status.edit(content="⚠️ 沒有做出投影片。" + (f"\n{answer[:1500]}" if answer else ""))
        return

    await status.edit(content=f"✅ 投影片完成：{state.get('pages', '?')} 頁，改了 {state['runs']} 版，"
                              f"{time.time() - t0:.0f} 秒")
    files = [discord.File(state["pptx"], filename=os.path.basename(state["pptx"]))]
    files += [discord.File(io.BytesIO(p), filename=f"preview-{i}.png")
              for i, p in enumerate(state.get("previews", [])[:4], 1)]
    await channel.send(content=(answer[:1700] + "\n\n⚠️ AI 草稿，內容、數據與來源請查證後再使用。"), files=files)
    for p in proposals:
        if message.guild is not None:
            await post_proposal(channel, p)


@client.event
async def on_raw_reaction_add(payload: discord.RawReactionActionEvent):
    """管理員在技能提案上按 ✅ / ❌。"""
    p = pending_skills.get(payload.message_id)
    emoji = str(payload.emoji)
    if not p or payload.user_id == client.user.id or emoji not in (APPROVE, REJECT):
        return
    if not is_admin(payload.member):
        return   # 一般成員按的不算
    channel = client.get_channel(payload.channel_id) or await client.fetch_channel(payload.channel_id)
    msg = await channel.fetch_message(payload.message_id)
    who = payload.member.display_name
    pending_skills.pop(payload.message_id, None)
    if emoji == APPROVE:
        why = skills.validate(p["name"], p["description"], p["content"])
        if why:
            await msg.reply(f"⚠️ 無法儲存技能 `{p['name']}`：{why}")
            return
        name = await run_blocking(skills.save_skill, p["name"], p["description"], p["content"])
        await msg.edit(content=msg.content.rsplit("\n", 1)[0] + f"\n{APPROVE} 已由 **{who}** 核准，技能 `{name}` 生效。")
    else:
        await msg.edit(content=msg.content.rsplit("\n", 1)[0] + f"\n{REJECT} 已由 **{who}** 拒絕。")
    try:
        await msg.clear_reactions()
    except discord.DiscordException:
        pass   # bot 沒有「管理訊息」權限就留著


async def cmd_skills(message: discord.Message, arg: str):
    """!skills 列出；!skill <名稱> 看內容；!skill del <名稱> 刪除（管理員）。"""
    channel = message.channel
    sub, _, rest = arg.partition(" ")
    if sub.lower() in ("del", "delete", "rm", "刪除"):
        if not is_admin(message.author):
            await channel.send("⛔ 只有管理員可以刪除技能。")
            return
        ok = await run_blocking(skills.delete_skill, rest.strip())
        await channel.send(f"🗑️ 已刪除技能 `{rest.strip()}`。" if ok else f"找不到技能 `{rest.strip()}`，用 `!skills` 查名稱。")
        return
    if arg:
        sk = await run_blocking(skills.get_skill, arg)
        if not sk:
            await channel.send(f"找不到技能 `{arg}`，用 `!skills` 查名稱。")
            return
        for part in chunk_text(f"🧠 **{skills.safe_name(arg)}**：{sk[0]}\n\n{sk[1]}"):
            await channel.send(part)
        return
    items = await run_blocking(skills.list_skills)
    if not items:
        await channel.send("🧠 技能庫還是空的。教我做法時說「把這個做法記成技能」，管理員核准後就會保留下來。")
        return
    text = f"🧠 **技能庫**（共 {len(items)} 個）\n" + "\n".join(f"• `{n}`：{d}" for n, d in items) \
        + "\n\n`!skill <名稱>` 看內容；管理員可用 `!skill del <名稱>` 刪除。"
    for part in chunk_text(text):
        await channel.send(part)


@client.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return

    is_dm = message.guild is None
    mentioned = client.user in message.mentions
    content = message.content
    if mentioned:  # 去掉 @bot 提及
        content = content.replace(f"<@{client.user.id}>", "").replace(f"<@!{client.user.id}>", "")
    content = content.strip()

    cmd, _, arg = content.partition(" ")
    cmd, arg = cmd.lower(), arg.strip()

    # 指令一律回應（不受頻道限制）
    if cmd == "!help":
        await message.channel.send(HELP_TEXT)
        return
    if cmd == "!reset":
        histories.pop(message.channel.id, None)
        await message.channel.send("🧹 已清空這個頻道的對話記憶。")
        return
    if cmd == "!models":
        await cmd_models(message.channel)
        return
    if cmd == "!tools":
        await cmd_tools(message.channel)
        return
    if cmd in ("!skills", "!skill"):
        await cmd_skills(message, arg)
        return
    if cmd == "!status":
        await cmd_model(message.channel, "")
        return
    if cmd == "!model":
        await cmd_model(message.channel, arg)
        return
    if cmd == "!ppt" and PPT_MODE == "code" and ENABLE_TOOLS:
        await cmd_slides(message, arg)
        return
    if cmd in ("!ppt", "!word", "!excel"):
        await cmd_generate(message, cmd[1:], arg)
        return
    if cmd == "!web":
        if arg:
            await cmd_chat(message, arg, do_web=True)
        return

    # 一般聊天：私訊、被提及一定回；否則只在允許頻道（或未限制時）回
    should_reply = is_dm or mentioned or ALLOWED_CHANNEL_ID is None \
        or message.channel.id == ALLOWED_CHANNEL_ID
    if should_reply and content and not content.startswith("!"):
        await cmd_chat(message, content, do_web=False)


if __name__ == "__main__":
    client.run(TOKEN)
