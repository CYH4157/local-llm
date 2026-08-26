"""
discord_bot.py — 把本地 Ollama 模型接到 Discord。

指令：
    (直接聊天)   在允許的頻道發訊息、@提及 bot、或私訊 → 一般問答（離線，不耗流量）
    !web <問題>  先查 DuckDuckGo 再回答（會用到網路）
    !reset       清空這個頻道的對話記憶
    !model       顯示目前使用的模型

設定都在同目錄的 .env（見 .env.example）。
"""

import os
import asyncio
import functools

import requests
import discord
from dotenv import load_dotenv

# --- 讀設定 -----------------------------------------------------------------
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"), override=True)

TOKEN         = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
OLLAMA_HOST   = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434").strip()
if not OLLAMA_HOST.startswith("http"):
    OLLAMA_HOST = "http://" + OLLAMA_HOST
# 0.0.0.0 是「監聽所有網卡」用的位址，不能拿來連線，改連本機
OLLAMA_HOST   = OLLAMA_HOST.replace("0.0.0.0", "127.0.0.1").rstrip("/")
MODEL         = os.getenv("MODEL", "qwen2.5:14b")
SYSTEM_PROMPT = os.getenv("SYSTEM_PROMPT", "你是研究室的 AI 助理，請用繁體中文回答。")
MAX_HISTORY   = int(os.getenv("MAX_HISTORY", "12"))
_allowed      = os.getenv("ALLOWED_CHANNEL_ID", "").strip()
ALLOWED_CHANNEL_ID = int(_allowed) if _allowed.isdigit() else None

SEARCH_ENGINE  = os.getenv("SEARCH_ENGINE", "google").strip().lower()
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "").strip()
GOOGLE_CSE_ID  = os.getenv("GOOGLE_CSE_ID", "").strip()

if not TOKEN or TOKEN.startswith("貼上"):
    raise SystemExit("請先在 .env 填入 DISCORD_BOT_TOKEN")

# --- 對話記憶（以頻道為單位）------------------------------------------------
histories: dict[int, list[dict]] = {}


def _trim(msgs: list[dict]) -> list[dict]:
    """只保留最近 MAX_HISTORY 則，避免爆 VRAM / 變慢。"""
    if len(msgs) > MAX_HISTORY:
        return msgs[-MAX_HISTORY:]
    return msgs


# --- 呼叫 Ollama（同步；會丟到執行緒跑，不卡住 bot）------------------------
def ollama_chat(messages: list[dict]) -> str:
    payload = {
        "model": MODEL,
        "messages": [{"role": "system", "content": SYSTEM_PROMPT}] + messages,
        "stream": False,
    }
    r = requests.post(f"{OLLAMA_HOST}/api/chat", json=payload, timeout=600)
    r.raise_for_status()
    return r.json()["message"]["content"].strip()


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
            try:
                return _ddg_search(query, n) + f"\n\n（註：Google 搜尋失敗改用備援：{e}）"
            except Exception:
                raise
    return _ddg_search(query, n)


# --- 工具：把長訊息切成 Discord 允許的 2000 字以內 -------------------------
def chunk_text(text: str, size: int = 1900) -> list[str]:
    if not text:
        return ["（空白回應）"]
    return [text[i:i + size] for i in range(0, len(text), size)]


# --- Discord 事件 -----------------------------------------------------------
intents = discord.Intents.default()
intents.message_content = True
client = discord.Client(intents=intents)


@client.event
async def on_ready():
    print(f"[已上線] {client.user}  模型={MODEL}  Ollama={OLLAMA_HOST}")


async def run_blocking(func, *args):
    """在執行緒池跑同步函式，避免卡住事件迴圈。"""
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, functools.partial(func, *args))


@client.event
async def on_message(message: discord.Message):
    if message.author.bot:
        return

    is_dm = message.guild is None
    mentioned = client.user in message.mentions
    content = message.content

    # 去掉開頭的 @bot 提及
    if mentioned:
        content = content.replace(f"<@{client.user.id}>", "").replace(f"<@!{client.user.id}>", "")
    content = content.strip()

    # --- 指令 ---
    if content.startswith("!reset"):
        histories.pop(message.channel.id, None)
        await message.channel.send("🧹 已清空這個頻道的對話記憶。")
        return

    if content.startswith("!model"):
        await message.channel.send(f"🤖 目前模型：`{MODEL}`")
        return

    do_web = content.startswith("!web")
    if do_web:
        content = content[len("!web"):].strip()

    # --- 判斷是否要回應 ---
    # 私訊、被提及、!web 一定回；否則只在允許頻道（或未限制時）回一般訊息
    should_reply = is_dm or mentioned or do_web
    if not should_reply:
        if ALLOWED_CHANNEL_ID is None:
            should_reply = True  # 未限制頻道 → 都回
        else:
            should_reply = (message.channel.id == ALLOWED_CHANNEL_ID)
    if not should_reply or not content:
        return

    hist = histories.setdefault(message.channel.id, [])

    async with message.channel.typing():
        try:
            user_content = content
            if do_web:
                results = await run_blocking(web_search, content)
                user_content = (
                    f"參考以下網路搜尋結果回答問題，並在句末標註引用編號 [n]：\n\n"
                    f"{results}\n\n問題：{content}"
                )

            hist.append({"role": "user", "content": user_content})
            hist[:] = _trim(hist)

            answer = await run_blocking(ollama_chat, list(hist))
            hist.append({"role": "assistant", "content": answer})
            hist[:] = _trim(hist)

        except requests.exceptions.ConnectionError:
            await message.channel.send("⚠️ 連不上 Ollama，請確認 `ollama serve` 有在跑。")
            return
        except Exception as e:  # noqa: BLE001
            await message.channel.send(f"⚠️ 發生錯誤：`{e}`")
            return

    for part in chunk_text(answer):
        await message.channel.send(part)


if __name__ == "__main__":
    client.run(TOKEN)
