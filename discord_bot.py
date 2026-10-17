"""
discord_bot.py — 把本地 vLLM 模型（經 llama-swap）接到 Discord。

指令：
    (直接聊天)                在允許的頻道發訊息、@提及 bot、或私訊 → 一般問答（離線）
    !web <問題>               先上網搜尋再回答
    !ppt <主題/需求>          產生 PowerPoint (.pptx)
    !word [計畫|報告] <需求>  產生 Word (.docx)；計畫=國科會計畫格式、報告=課堂報告
    !excel <需求>             產生 Excel (.xlsx)
    !model                    顯示目前模型與可用模型
    !model <名稱>             切換模型（全體共用，第一次載入約 1~3 分鐘）
    !status                   看 GPU 上目前載入的模型
    !reset                    清空這個頻道的對話記憶
    !help                     顯示說明

產檔指令可附加 .txt / .md / .docx / .pdf 檔，或「回覆」某則訊息，當作參考資料。
設定都在同目錄的 .env（見 .env.example）。
"""

import asyncio
import functools
import io
import json
import os
import time

import discord
import requests
from dotenv import load_dotenv

# 先讀 .env，llm_client / office_gen 在 import 時會讀環境變數
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(BASE_DIR, ".env"), override=True)

import llm_client  # noqa: E402
import office_gen  # noqa: E402

# --- 讀設定 -----------------------------------------------------------------
TOKEN          = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
DEFAULT_MODEL  = os.getenv("DEFAULT_MODEL", "qwen3-8b").strip()
SYSTEM_PROMPT  = os.getenv("SYSTEM_PROMPT", "你是研究室的 AI 助理，請用台灣繁體中文回答。")
MAX_HISTORY    = int(os.getenv("MAX_HISTORY", "10"))
# 記憶的總字數上限（8GB 顯卡上下文約 8k tokens，別塞太多）
HISTORY_CHARS  = int(os.getenv("HISTORY_MAX_CHARS", "4000"))
# 附件 / 回覆訊息當參考資料時，最多讀幾個字
REF_MAX_CHARS  = int(os.getenv("REF_MAX_CHARS", "3000"))
TO_TRADITIONAL = os.getenv("TO_TRADITIONAL", "1").strip() not in ("0", "false", "False", "")
_allowed       = os.getenv("ALLOWED_CHANNEL_ID", "").strip()
ALLOWED_CHANNEL_ID = int(_allowed) if _allowed.isdigit() else None

SEARCH_ENGINE  = os.getenv("SEARCH_ENGINE", "google").strip().lower()
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "").strip()
GOOGLE_CSE_ID  = os.getenv("GOOGLE_CSE_ID", "").strip()

STATE_FILE = os.path.join(BASE_DIR, "bot_state.json")

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


# --- 目前模型（全體共用；GPU 一次只放得下一個）-----------------------------
def _load_state() -> dict:
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_state():
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump({"model": current_model}, f, ensure_ascii=False)
    except OSError as e:
        print(f"[警告] 無法寫入 {STATE_FILE}：{e}")


current_model: str = _load_state().get("model") or DEFAULT_MODEL
switch_lock = asyncio.Lock()

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
    if isinstance(e, requests.exceptions.ConnectionError):
        return ("⚠️ 連不上模型服務（llama-swap）。請確認 WSL 裡的服務有在跑：\n"
                "`wsl -- systemctl status llama-swap`")
    if isinstance(e, requests.exceptions.Timeout):
        return "⚠️ 模型回應逾時（可能正在第一次載入 / 下載模型），請稍後再試。"
    if "401" in str(e) or "Unauthorized" in str(e):
        return "⚠️ 模型服務拒絕連線（API 金鑰錯誤）。請確認 `.env` 的 `LLM_API_KEY` 和 WSL 端一致，必要時重跑 deploy.ps1。"
    if llm_client.is_context_error(e):
        return "⚠️ 內容太長，超過模型的上下文長度。請用 `!reset` 清記憶，或縮短參考資料。"
    return f"⚠️ 發生錯誤：`{str(e)[:300]}`"


HELP_TEXT = """**📖 使用說明**
• 直接聊天：@我、私訊，或在指定頻道發言
• `!web <問題>`：上網搜尋後回答
• `!ppt <主題>`：產生簡報 .pptx（含講者備註）
• `!word 計畫 <題目>`：國科會研究計畫草稿 .docx
• `!word 報告 <主題>`：課堂報告 .docx
• `!word <需求>`：一般文件 .docx
• `!excel <需求>`：Excel 表格 .xlsx（可含公式）
• `!model` / `!model <名稱>`：查看 / 切換模型（全體共用）
• `!status`：GPU 上目前載入的模型
• `!reset`：清空這個頻道的記憶

💡 產檔指令可以**附上 .txt/.md/.docx/.pdf** 或**回覆某則訊息**，當作參考資料。
⚠️ 本地小模型產出的是**草稿**，數據與文獻請務必自行查證。"""


# --- Discord 事件 -----------------------------------------------------------
intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)


@client.event
async def on_ready():
    print(f"[已上線] {client.user}  模型={current_model}  API={llm_client.BASE_URL}")


async def cmd_model(channel, arg: str):
    global current_model
    try:
        models = await run_blocking(llm_client.list_models)
    except Exception as e:  # noqa: BLE001
        await channel.send(friendly_error(e))
        return
    ids = [m["id"] for m in models]

    if not arg:
        lines = [f"🤖 目前模型：`{current_model}`", "", "**可用模型**（`!model <名稱>` 切換）："]
        for m in models:
            mark = "👉 " if m["id"] == current_model else "• "
            desc = f" — {m['description']}" if m["description"] else ""
            lines.append(f"{mark}`{m['id']}`{desc}")
        await channel.send("\n".join(lines))
        return

    if arg not in ids:
        await channel.send(f"❓ 沒有 `{arg}` 這個模型。可用：{', '.join(f'`{i}`' for i in ids)}")
        return
    if arg == current_model:
        await channel.send(f"✅ 已經是 `{arg}` 了。")
        return

    async with switch_lock:
        current_model = arg
        _save_state()
        if arg in await run_blocking(llm_client.running_models):
            await channel.send(f"✅ 已切換為 `{arg}`。")
            return
        await channel.send(f"⏳ 切換到 `{arg}`，載入中（第一次需下載模型，可能要幾分鐘）…")
        t0 = time.time()
        try:
            await run_blocking(llm_client.chat, arg,
                               [{"role": "user", "content": "hi"}], max_tokens=1)
            await channel.send(f"✅ `{arg}` 已就緒（{time.time() - t0:.0f} 秒）。")
        except Exception as e:  # noqa: BLE001
            await channel.send(friendly_error(e) + "\n模型已記為目前模型，下一次提問時會再嘗試載入。")


async def cmd_status(channel):
    running = await run_blocking(llm_client.running_models)
    loaded = "、".join(f"`{m}`" for m in running) if running else "（無，閒置已卸載；下次提問會自動載入）"
    await channel.send(f"🤖 目前選用：`{current_model}`\n🖥️ GPU 已載入：{loaded}")


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
            data = await run_blocking(llm_client.chat_json, current_model, msgs, schema, kind)
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
            msgs = [{"role": "system", "content": SYSTEM_PROMPT}] + _trim(
                hist + [{"role": "user", "content": user_content}])
            answer = tw(await run_blocking(llm_client.chat, current_model, msgs))
        except Exception as e:  # noqa: BLE001
            await channel.send(friendly_error(e))
            return

    # 記憶只存原始問題，不存整包搜尋結果，省上下文
    hist.append({"role": "user", "content": content})
    hist.append({"role": "assistant", "content": answer})
    hist[:] = _trim(hist)

    for part in chunk_text(answer):
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
    if cmd == "!model":
        await cmd_model(message.channel, arg)
        return
    if cmd == "!status":
        await cmd_status(message.channel)
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
