"""
stockfeed.py — 免費股票行情與財經新聞。

- 行情：Yahoo Finance 非官方公開端點（v1 搜尋 + v8 chart），無需 API 金鑰。
- 新聞：Google News RSS，無需 API 金鑰。
- 限流：內建簡易快取；請勿把查詢間隔調得太短，以免被來源網站暫時封鎖（HTTP 429/999）。

資料僅供參考，可能有延遲或中斷，不構成投資建議。
"""

import email.utils
import html
import json
import os
import re
import time
import unicodedata
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional
from urllib.parse import quote_plus

import requests

TZ_TAIPEI = timezone(timedelta(hours=8))
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) local-llm-discord-bot/1.0"
_TIMEOUT = 15
_QUOTE_CACHE_TTL = 20
_SEARCH_CACHE_TTL = 300
_NEWS_CACHE_TTL = 300
_LIST_CACHE_TTL = int(os.environ.get("STOCK_LIST_CACHE_TTL", str(12 * 3600)))
_QUOTES_PER_CALL = 12

_quote_cache = {}
_search_cache = {}
_news_cache = {}
_tw_list_cache = {}

_NEWS_INTERVAL_DEFAULT = 1800

# 台股公司名稱 → 代號：上市/上櫃官方公司基本資料（每日更新，無需金鑰）。
_TW_LIST_SOURCES = [
    (
        "上市",
        ".TW",
        os.environ.get(
            "STOCK_TWSE_LIST_URL",
            "https://openapi.twse.com.tw/v1/opendata/t187ap03_L",
        ),
    ),
    (
        "上櫃",
        ".TWO",
        os.environ.get(
            "STOCK_TPEX_LIST_URL",
            "https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O",
        ),
    ),
]

# 常見美股中文別名（只放辨識度高、幾乎不會混淆的；公司全名仍交給 LLM 翻譯）。
_STOCK_ALIASES = {
    "蘋果": "AAPL",
    "輝達": "NVDA",
    "英偉達": "NVDA",
    "特斯拉": "TSLA",
    "微軟": "MSFT",
    "谷歌": "GOOGL",
    "亞馬遜": "AMZN",
    "臉書": "META",
    "英特爾": "INTC",
    "超微": "AMD",
    "博通": "AVGO",
    "網飛": "NFLX",
    "奈飛": "NFLX",
    "可口可樂": "KO",
    "波音": "BA",
    "迪士尼": "DIS",
    "麥當勞": "MCD",
    "耐吉": "NKE",
    "耐克": "NKE",
    "英飛凌": "IFX.DE",
}

_DEFAULT_FEEDS = [
    ("Google 財經", "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
    ("台股新聞", "https://news.google.com/rss/search?q=%E5%8F%B0%E8%82%A1%20OR%20%E5%8F%B0%E7%81%A3%E8%82%A1%E5%B8%82%20when%3A1d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
    ("美股新聞", "https://news.google.com/rss/search?q=%E7%BE%8E%E8%82%A1%20OR%20%E9%82%A3%E6%96%AF%E9%81%94%E5%85%8B%20OR%20%E8%B2%BB%E5%9F%8E%E5%8D%8A%E5%B0%8E%E9%AB%94%20when%3A1d&hl=zh-TW&gl=TW&ceid=TW:zh-Hant"),
]

_DEFAULT_WATCHLIST = [
    ("大盤加權指數", "^TWII"),
    ("台積電", "2330.TW"),
    ("元大台灣50", "0050.TW"),
    ("S&P 500", "^GSPC"),
    ("Nasdaq", "^IXIC"),
    ("費城半導體", "^SOX"),
    ("NVIDIA", "NVDA"),
]

_DISCLAIMER = "資料僅供參考，可能有延遲或中斷，不構成投資建議。"


@dataclass
class _TWCompany:
    code: str
    name: str
    market: str   # "上市" / "上櫃"
    suffix: str   # ".TW" / ".TWO"

    @property
    def symbol(self):
        return self.code + self.suffix


def _fetch_tw_lists():
    """抓上市/上櫃公司清單並快取；失敗回 None（下次重試，不快取空結果）。"""
    cached = _cache_get(_tw_list_cache, "all", _LIST_CACHE_TTL)
    if cached is not None:
        return cached
    companies = []
    errors = []
    for label, suffix, url in _TW_LIST_SOURCES:
        try:
            data = _get_json(url)
            if not isinstance(data, list):
                raise ValueError("unexpected response")
            count = 0
            for row in data:
                code = str(row.get("公司代號") or row.get("SecuritiesCompanyCode") or "").strip()
                name = str(row.get("公司簡稱") or row.get("CompanyAbbreviation") or "").strip()
                # 只保留普通股票代號（4~6 位數字），過濾受益憑證、特別股等
                if re.fullmatch(r"\d{4,6}", code) and name:
                    companies.append(_TWCompany(code, name, label, suffix))
                    count += 1
            print(f"[stockfeed] {label}公司清單：{count} 筆", flush=True)
        except Exception as e:
            errors.append(f"{label}: {e}")
    if not companies:
        print(f"[stockfeed] 台股清單抓取失敗：{'; '.join(errors) or '無資料'}", flush=True)
        return None
    if errors:
        print(f"[stockfeed] 部分清單失敗：{'; '.join(errors)}", flush=True)
    _cache_set(_tw_list_cache, "all", companies)
    return companies


def _tw_company_candidates(query, market="auto"):
    """用中文/簡稱在官方清單找台股代號，回傳 [(symbol, display_name)]（最多 5 筆）。

    比對順序：完全相符 > 前綴相符 > 部分包含。找不到回傳 []，清單不可用回傳 None。
    """
    companies = _fetch_tw_lists()
    if companies is None:
        return None
    q = _normalize_name(query)
    if not q:
        return []
    targets = {
        "tw": {".TW"},
        "two": {".TWO"},
        "auto": {".TW", ".TWO"},
    }.get(market, set())
    if not targets:
        return []

    exact, prefix, partial = [], [], []
    for c in companies:
        if c.suffix not in targets:
            continue
        name = _normalize_name(c.name)
        if name == q:
            exact.append(c)
        elif name.startswith(q):
            prefix.append(c)
        elif q in name:
            partial.append(c)

    picked = (exact or prefix or partial)[:5]
    return [(c.symbol, f"{c.name}（{c.market}）") for c in picked]


def _env(name, default=""):
    return (os.environ.get(name) or default).strip()


def _env_bool(name, default=False):
    val = _env(name).lower()
    if not val:
        return default
    return val in {"1", "true", "yes", "y", "on"}


def _env_int(name, default, minimum=None, maximum=None):
    try:
        num = int(_env(name, str(default)))
    except ValueError:
        return default
    if minimum is not None:
        num = max(minimum, num)
    if maximum is not None:
        num = min(maximum, num)
    return num


def _get_json(url, params=None):
    resp = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=_TIMEOUT)
    if resp.status_code in (429, 999):
        raise RuntimeError("Yahoo 暫時限流，請稍後再試")
    resp.raise_for_status()
    return resp.json()


def _cache_get(cache, key, ttl):
    hit = cache.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    return None


def _cache_set(cache, key, value):
    cache[key] = (time.time(), value)


def looks_like_symbol(query):
    """只接受明確的代號／指數格式，例如 2330、2330.TW、AAPL、^TWII。"""
    q = (query or "").strip().upper()
    return bool(re.fullmatch(r"(\d{4,6}(\.(TW|TWO))?|\^?[A-Z][A-Z0-9.-]{0,11})", q))


def normalize_symbol(query, market="auto"):
    """回傳 (Yahoo 代號, 處理說明, 錯誤訊息)。"""
    raw = (query or "").strip().upper().replace(" ", "")
    if not raw:
        return None, "", "請輸入股票代號，例如 2330、2330.TW、AAPL、^TWII"

    if raw.startswith("TWO:"):
        return f"{raw[4:]}.TWO", "已指定上櫃市場：", ""
    if raw.startswith("TW:"):
        return f"{raw[3:]}.TW", "已指定上市市場：", ""

    if re.fullmatch(r"\d{4,6}", raw):
        if market == "us":
            return None, "", "台股純數字代號請改用市場 auto；美股通常不是純數字代號"
        for suffix, market_note in ((".TW", "上市"), (".TWO", "上櫃")):
            symbol = raw + suffix
            try:
                if _fetch_chart(symbol):
                    return symbol, f"台股數字代號自動判定為{market_note}：", ""
            except Exception:
                continue
        return None, "", f"找不到台股代號 {raw}（已嘗試 .TW 與 .TWO），請確認代號"

    if re.fullmatch(r"\d{4,6}\.(TW|TWO)", raw):
        if market == "us":
            return None, "", "這是台股代號格式，請改用市場 auto"
        return raw, "已使用明確台股代號：", ""

    if market == "tw":
        return None, "", "市場指定為台股時，請輸入 4~6 位數代號，或加 .TW / .TWO"
    if not re.fullmatch(r"\^?[A-Z][A-Z0-9.-]{0,11}", raw):
        return None, "", "代號格式不正確；公司名稱請改用「名稱＋市場」搜尋"
    return raw, "代號直接查詢：", ""


def _fetch_chart(symbol):
    data = _get_json(
        f"https://query2.finance.yahoo.com/v8/finance/chart/{quote_plus(symbol)}",
        {"interval": "1m", "range": "1d"},
    )
    result = (data.get("chart", {}).get("result") or [None])[0]
    if not result:
        err = data.get("chart", {}).get("error") or {}
        raise RuntimeError(err.get("description") or f"查不到 {symbol}")
    return result


def _format_price(value):
    return f"{value:,.2f}"


def quote(query, market="auto"):
    """查詢一只股票；回傳可直接貼到 Discord 的文字。"""
    symbol, note, err = normalize_symbol(query, market)
    if err:
        return f"❌ {err}\n{_DISCLAIMER}"
    if market == "us" and symbol.endswith((".TW", ".TWO")):
        return f"❌ {symbol} 是台股代號，請改用市場 auto。\n{_DISCLAIMER}"

    cached = _cache_get(_quote_cache, symbol, _QUOTE_CACHE_TTL)
    if cached:
        return cached

    try:
        result = _fetch_chart(symbol)
        meta = result.get("meta", {})
        quote_data = (result.get("indicators", {}).get("quote") or [{}])[0]
        timestamps = result.get("timestamp") or []
        closes = [v for v in (quote_data.get("close") or []) if v is not None]
        volumes = [v for v in (quote_data.get("volume") or []) if v is not None]
        price = meta.get("regularMarketPrice") or (closes[-1] if closes else None)
        prev = meta.get("chartPreviousClose") or meta.get("previousClose")
        change = (price - prev) if (price is not None and prev) else 0.0
        change_pct = 0.0
        if prev:
            change_pct = change / prev * 100

        lines = [
            f"📈 **{meta.get('longName') or meta.get('shortName') or symbol}**（{symbol}）",
            f"{note}{meta.get('fullExchangeName') or meta.get('exchangeName') or '交易所未知'}",
            (
                f"成交價：**{_format_price(price)} {meta.get('currency', '')}**　"
                f"{'+' if change >= 0 else ''}{change:,.2f}（{'+' if change >= 0 else ''}{change_pct:.2f}%）"
            ),
        ]
        if volumes:
            lines.append(f"最近一根 1 分 K 成交量：{volumes[-1]:,}")
        if timestamps:
            seen = datetime.fromtimestamp(timestamps[-1], TZ_TAIPEI)
        else:
            seen = datetime.now(TZ_TAIPEI)
        market_state = meta.get("marketState", "未知")
        state_zh = {
            "REGULAR": "盤中",
            "PRE": "盤前",
            "POST": "盤後",
            "PREPRE": "盤前",
            "POSTPOST": "盤後",
            "CLOSED": "已收盤／最近成交",
        }.get(market_state, market_state)
        delay_note = "來源近即時更新，仍可能延遲" if market_state in {"REGULAR", "PRE", "POST", "PREPRE", "POSTPOST"} else "非盤中，顯示最近成交／收盤價"
        lines.append(f"市場狀態：{state_zh}；資料時間：{seen:%Y-%m-%d %H:%M:%S}（台北時間）")
        lines.append(f"來源：Yahoo Finance 非官方公開端點；{delay_note}。")
        lines.append(_DISCLAIMER)
        text = "\n".join(lines)
    except requests.RequestException:
        text = f"❌ 查詢 **{symbol}** 時連線失敗或來源暫時不可用，請稍後再試。\n{_DISCLAIMER}"
    except (RuntimeError, ValueError, KeyError, IndexError, TypeError) as exc:
        text = f"❌ 查詢 **{symbol}** 失敗：{exc}\n{_DISCLAIMER}"
    except Exception as exc:
        text = f"❌ 查詢 **{symbol}** 時發生未預期錯誤：{exc}\n{_DISCLAIMER}"

    _cache_set(_quote_cache, symbol, text)
    return text


def quote_many(query, market="auto"):
    """一次查多檔，以逗號／空白分隔；上限 12 檔。"""
    parts = [p for p in re.split(r"[,，、\s]+", (query or "").strip()) if p]
    if not parts:
        return "❌ 請至少輸入一個代號，例如 `2330, 2317, AAPL`。"
    if len(parts) > _QUOTES_PER_CALL:
        return f"❌ 一次最多查 {_QUOTES_PER_CALL} 檔，請分批查詢。"
    return "\n\n".join(quote(part, market) for part in parts)


def search_symbol(query, market="auto"):
    """用公司名稱或模糊關鍵字搜尋代號。"""
    q = (query or "").strip()
    if not q:
        return "❌ 請輸入公司名稱或關鍵字，例如 `台積電` 或 `NVIDIA`。"
    if looks_like_symbol(q) and not re.search(r"[\u4e00-\u9fff]", q):
        return "💡 這看起來像代號，請直接用股票查詢功能；如果要找名稱，請輸入公司名稱。"

    key = f"{q}|{market}"
    cached = _cache_get(_search_cache, key, _SEARCH_CACHE_TTL)
    if cached:
        return cached

    try:
        data = _get_json(
            "https://query2.finance.yahoo.com/v1/finance/search",
            {"q": q, "quotesCount": 8, "newsCount": 0, "enableFuzzyQuery": "true"},
        )
        quotes = data.get("quotes") or []
        rows = []
        for item in quotes:
            symbol = item.get("symbol")
            name = item.get("shortname") or item.get("longname")
            exch = item.get("exchDisp") or item.get("exchange")
            kind = item.get("quoteType")
            if not symbol or not name:
                continue
            if market == "tw" and not symbol.endswith((".TW", ".TWO")):
                continue
            if market == "us" and symbol.endswith((".TW", ".TWO")):
                continue
            rows.append(f"`{symbol}` — {name}｜{exch or '交易所未知'}｜{kind or '類型未知'}")
        if not rows:
            text = f"找不到「{q}」的可用標的；請改用更完整公司名稱或股票代號。"
        else:
            text = "🔎 搜尋結果（Yahoo Finance）：\n" + "\n".join(rows[:8])
            text += "\n\n確認後請用列出來的完整代號查行情；台股也可輸入 4~6 位數代號自動判定 .TW／.TWO。"
    except requests.RequestException:
        text = "❌ 搜尋服務暫時連線失敗，請稍後再試。"
    except Exception as exc:
        text = f"❌ 搜尋失敗：{exc}"
    _cache_set(_search_cache, key, text)
    return text


def _parse_feeds():
    raw = _env("STOCK_NEWS_FEEDS")
    if not raw:
        return list(_DEFAULT_FEEDS)
    feeds = []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            for item in data:
                if not isinstance(item, dict):
                    continue
                name = str(item.get("name") or "").strip()
                url = str(item.get("url") or "").strip()
                if name and url:
                    feeds.append((name, url))
    except Exception:
        pass
    return feeds or list(_DEFAULT_FEEDS)


def _parse_watchlist():
    raw = _env("STOCK_WATCHLIST")
    if raw:
        items = []
        for part in raw.split(","):
            part = part.strip()
            if not part:
                continue
            if "=" in part:
                name, symbol = part.split("=", 1)
            elif ":" in part:
                name, symbol = part.split(":", 1)
            else:
                name, symbol = part, part
            name, symbol = name.strip(), symbol.strip()
            if name and symbol:
                items.append((name, symbol))
        return items[:10]
    return list(_DEFAULT_WATCHLIST)[: _env_int("STOCK_PUSH_QUOTES_MAX", 5, 0, 10)]


def _parse_pub_date(raw):
    if not raw:
        return ""
    try:
        dt = email.utils.parsedate_to_datetime(raw)
        if dt and dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        if dt:
            return dt.astimezone(TZ_TAIPEI).strftime("%Y-%m-%d %H:%M")
    except Exception:
        pass
    return ""


def fetch_latest_items(url, limit=5):
    """抓 RSS，回傳 [(標題, 連結, 來源, 時間字串, 識別鍵)]。"""
    resp = requests.get(url, headers={"User-Agent": UA}, timeout=_TIMEOUT)
    if resp.status_code == 429:
        raise RuntimeError("RSS 暫時限流")
    resp.raise_for_status()
    try:
        root = ET.fromstring(resp.content)
    except ET.ParseError:
        text = resp.content.decode("utf-8", errors="replace")
        start = text.find("<rss")
        if start < 0:
            start = text.find("<feed")
        if start < 0:
            raise RuntimeError("RSS 格式無法解析")
        root = ET.fromstring(text[start:].encode("utf-8"))

    items = []
    for item in root.findall(".//item"):
        title = html.unescape((item.findtext("title") or "").strip())
        link = (item.findtext("link") or "").strip()
        source_el = item.find("source")
        source = html.unescape((source_el.text or "").strip()) if source_el is not None and source_el.text else ""
        published = _parse_pub_date(item.findtext("pubDate"))
        guid = (item.findtext("guid") or "").strip()
        if not title or not link:
            continue
        items.append((title, link, source, published, guid or link))
        if len(items) >= limit:
            break
    return items


def latest_news(topic="", limit=5):
    """查最新財經新聞；topic 可用於台股／美股關鍵字。"""
    limit = _env_int("STOCK_NEWS_MAX", limit, 1, 10)
    feeds = list(_DEFAULT_FEEDS)
    t = (topic or "").strip().lower()
    if t in {"tw", "taiwan", "台股", "台灣", "加權"}:
        feeds = [_DEFAULT_FEEDS[1]]
    elif t in {"us", "usa", "america", "美股", "美國", "nasdaq", "那斯達克"}:
        feeds = [_DEFAULT_FEEDS[2]]

    sections = []
    for name, url in feeds:
        cached = _cache_get(_news_cache, f"{url}|{limit}", _NEWS_CACHE_TTL)
        if cached:
            sections.append(cached)
            continue
        try:
            rows = []
            for title, link, source, published, _ in fetch_latest_items(url, limit):
                meta = "｜".join(x for x in (source, published) if x)
                rows.append(f"• [{title}]({link})" + (f"\n  {meta}" if meta else ""))
            text = f"📰 **{name}**（Google News RSS）\n" + ("\n".join(rows) if rows else "目前沒有抓到新聞。")
        except requests.RequestException:
            text = f"📰 **{name}**\n⚠️ RSS 暫時無法連線，請稍後再試。"
        except Exception as exc:
            text = f"📰 **{name}**\n⚠️ RSS 解析失敗：{exc}"
        _cache_set(_news_cache, f"{url}|{limit}", text)
        sections.append(text)

    fetched = datetime.now(TZ_TAIPEI)
    return (
        "\n\n".join(sections)
        + f"\n\n抓取時間：{fetched:%Y-%m-%d %H:%M:%S}（台北時間）；來源：Google News RSS 免費公開 feed。"
        + "新聞連結與時間以原始發布來源為準，RSS 可能延遲或暫時中斷。"
    )


class StockNewsBroadcaster:
    """每 30 分鐘推播新聞＋自選行情的背景排程。"""

    def __init__(self, bot, send_message):
        self.bot = bot
        self.send_message = send_message
        self.task = None
        self.started = False
        self.seen = set()
        self.seen_order = []
        self.news_lock = False

    @property
    def enabled(self):
        return self._check_enabled()

    def _check_enabled(self):
        if not _env_bool("STOCK_FEEDS_ENABLED", False):
            return False
        if not _env("STOCK_NEWS_CHANNEL_ID"):
            return False
        return True

    async def start(self):
        if self.started or not self._check_enabled():
            return
        self.started = True
        self.task = self.bot.loop.create_task(self._run())

    async def stop(self):
        if self.task:
            self.task.cancel()
            try:
                await self.task
            except Exception:
                pass
            self.task = None

    async def _run(self):
        await self.bot.wait_until_ready()
        # 啟動後先暖身 seen，避免機器人重開時把目前 RSS 內容整批重發。
        await self._tick(warmup=True)
        while not self.bot.is_closed():
            interval = _env_int("STOCK_NEWS_INTERVAL_MIN", 30, 15, 360)
            try:
                await __import__("asyncio").sleep(interval * 60)
            except Exception:
                break
            await self._tick(warmup=False)

    async def _tick(self, warmup=False):
        if self.news_lock:
            return
        self.news_lock = True
        try:
            if _env_bool("STOCK_NEWS_PRIME_ON_START", True) or not warmup:
                await self._broadcast_news(warmup=warmup)
            if not warmup and _env_bool("STOCK_PUSH_QUOTES", True):
                await self._broadcast_quotes()
            if not warmup:
                self.bot.log(f"[stockfeed] 推播完成，next={_env_int('STOCK_NEWS_INTERVAL_MIN', 30, 15, 360)}min")
        finally:
            self.news_lock = False

    def _remember(self, key):
        if key in self.seen:
            return False
        self.seen.add(key)
        self.seen_order.append(key)
        if len(self.seen_order) > _env_int("STOCK_NEWS_SEEN_MAX", 500, 50, 5000):
            old = self.seen_order.pop(0)
            self.seen.discard(old)
        return True

    async def _broadcast_news(self, warmup=False):
        max_items = _env_int("STOCK_NEWS_MAX", 5, 1, 10)
        batches = []
        for name, url in _parse_feeds():
            try:
                items = await __import__("asyncio").to_thread(fetch_latest_items, url, max(10, max_items))
            except Exception as exc:
                self.bot.log(f"[stockfeed] RSS {name} 失敗：{exc}")
                continue
            fresh = [item for item in items if self._remember(item[4])]
            if warmup or not fresh:
                continue
            fresh = fresh[:max_items]
            rows = []
            for title, link, source, published, _key in fresh:
                meta = "｜".join(x for x in (source, published) if x)
                rows.append(f"• [{title}]({link})" + (f"\n  {meta}" if meta else ""))
            batches.append(f"📰 **{name}**\n" + "\n".join(rows))
        if batches:
            text = (
                "📣 30 分鐘財經更新\n\n"
                + "\n\n".join(batches)
                + "\n\n來源：Google News RSS；RSS 更新可能有延遲或中斷。資料僅供參考，不構成投資建議。"
            )
            await self.send_message(_env("STOCK_NEWS_CHANNEL_ID"), text)

    async def _broadcast_quotes(self):
        watchlist = _parse_watchlist()
        if not watchlist:
            return
        rows = []
        for name, symbol in watchlist:
            try:
                text = await __import__("asyncio").to_thread(quote, symbol, "auto")
            except Exception as exc:
                rows.append(f"• {name}（{symbol}）：查詢失敗 {exc}")
                continue
            compact = text.splitlines()
            if len(compact) >= 3 and compact[0].startswith("📈"):
                title = compact[0].replace("📈 **", "").replace("**", "")
                detail = compact[2]
                rows.append(f"• {title}：{detail}")
            else:
                rows.append(f"• {name}（{symbol}）：{compact[0] if compact else '無資料'}")
        if rows:
            text = (
                "📈 自選標的快訊\n"
                + "\n".join(rows)
                + "\n\n來源：Yahoo Finance 免費 API（近即時，可能延遲）；資料僅供參考，不構成投資建議。"
            )
            await self.send_message(_env("STOCK_NEWS_CHANNEL_ID"), text)
