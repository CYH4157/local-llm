"""
mcp_client.py — 讓 bot 連上 MCP server（stdio），把它們的工具轉成 OpenAI function calling 格式。

• 設定檔：mcp_servers.json（MCP_CONFIG 可改路徑）；enabled=false 或指令找不到（例如沒裝 npx）就略過
• 每個 server 一個背景 task，一直保持連線；bot 先上線，server 陸續就緒（uvx/npx 第一次要下載，比較慢）
• 安全：工具參數裡的網址若指向內網 / 本機（例如 127.0.0.1:8000 的 vLLM），一律擋掉（BLOCK_PRIVATE_URLS=0 可關）
"""

import asyncio
import ipaddress
import json
import os
import re
import shutil
import socket
from urllib.parse import urlparse

BOT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.getenv("MCP_CONFIG", os.path.join(BOT_DIR, "mcp_servers.json"))
INIT_TIMEOUT = int(os.getenv("MCP_INIT_TIMEOUT", "180"))     # 含第一次下載套件的時間
CALL_TIMEOUT = int(os.getenv("MCP_CALL_TIMEOUT", "120"))
BLOCK_PRIVATE_URLS = os.getenv("BLOCK_PRIVATE_URLS", "1").strip() not in ("0", "false", "False")

_URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.IGNORECASE)


def _expand(s: str) -> str:
    return s.replace("${BOT_DIR}", BOT_DIR.replace("\\", "/"))


def _which(cmd: str) -> str | None:
    """找指令；systemd 的 PATH 很短，額外找 ~/.local/bin（uv 預設裝這）與常見位置。"""
    extra = [os.path.expanduser("~/.local/bin"), os.path.expanduser("~/.cargo/bin"), "/usr/local/bin"]
    path = os.pathsep.join([os.environ.get("PATH", "")] + extra)
    return shutil.which(cmd, path=path)


def _safe_name(s: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", s)


def check_url(url: str) -> str | None:
    """網址指向內網 / 本機就回傳原因，安全則回傳 None。"""
    try:
        p = urlparse(url)
        host = p.hostname
        if p.scheme not in ("http", "https") or not host:
            return f"只允許 http/https 網址：{url}"
        infos = socket.getaddrinfo(host, None)
    except (ValueError, socket.gaierror, UnicodeError):
        return None   # 解析不到就交給工具自己報錯
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved \
                or ip.is_multicast or ip.is_unspecified:
            return f"基於安全考量，不允許存取內網或本機位址：{host}"
    return None


def _urls_in(obj) -> list[str]:
    if isinstance(obj, str):
        return _URL_RE.findall(obj)
    if isinstance(obj, dict):
        return [u for v in obj.values() for u in _urls_in(v)]
    if isinstance(obj, list):
        return [u for v in obj for u in _urls_in(v)]
    return []


class _Server:
    def __init__(self, name: str, cfg: dict):
        self.name = name
        self.cfg = cfg
        self.session = None
        self.tools: list = []
        self.error = ""
        self.stop = asyncio.Event()
        self.task: asyncio.Task | None = None


class MCPManager:
    def __init__(self, config_path: str = CONFIG_PATH):
        self.config_path = config_path
        self.servers: dict[str, _Server] = {}
        self.skipped: dict[str, str] = {}

    async def start(self) -> None:
        """啟動所有 server（不等它們就緒，立刻返回）。"""
        try:
            from mcp import ClientSession, StdioServerParameters  # noqa: F401
        except ImportError:
            print("[MCP] 沒裝 mcp 套件，略過所有 MCP 工具（pip install -r requirements.txt）")
            return
        try:
            with open(self.config_path, encoding="utf-8") as f:
                conf = json.load(f).get("servers", {})
        except (OSError, json.JSONDecodeError) as e:
            print(f"[MCP] 讀不到設定檔 {self.config_path}：{e}")
            return
        os.makedirs(os.path.join(BOT_DIR, "data"), exist_ok=True)
        for name, cfg in conf.items():
            if not cfg.get("enabled", True):
                continue
            if not _which(cfg.get("command", "")):
                self.skipped[name] = f"找不到指令 {cfg.get('command')}"
                print(f"[MCP] 略過 {name}：{self.skipped[name]}")
                continue
            srv = _Server(name, cfg)
            self.servers[name] = srv
            srv.task = asyncio.create_task(self._run(srv), name=f"mcp-{name}")

    async def _run(self, srv: _Server) -> None:
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        cfg = srv.cfg
        env = {**os.environ, **{k: _expand(str(v)) for k, v in cfg.get("env", {}).items()}}
        params = StdioServerParameters(
            command=_which(cfg["command"]) or cfg["command"],
            args=[_expand(a) for a in cfg.get("args", [])],
            env=env,
        )
        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await asyncio.wait_for(session.initialize(), INIT_TIMEOUT)
                    srv.tools = (await asyncio.wait_for(session.list_tools(), 60)).tools
                    srv.session = session
                    print(f"[MCP] {srv.name} 就緒：{', '.join(t.name for t in srv.tools)}")
                    await srv.stop.wait()
        except asyncio.CancelledError:
            raise
        except BaseException as e:  # noqa: BLE001  (含 anyio 的 ExceptionGroup)
            while isinstance(e, BaseExceptionGroup) and e.exceptions:
                e = e.exceptions[0]   # 取出真正的原因
            srv.error = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            print(f"[MCP] {srv.name} 啟動失敗：{srv.error}")
        finally:
            srv.session = None
            srv.tools = []

    async def wait_ready(self, timeout: float = INIT_TIMEOUT) -> None:
        """等所有 server 就緒或失敗（selftest 用）。"""
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            if all(s.session or s.error or (s.task and s.task.done()) for s in self.servers.values()):
                return
            await asyncio.sleep(0.5)

    def _index(self) -> dict[str, tuple[_Server, object]]:
        idx = {}
        for srv in self.servers.values():
            if not srv.session:
                continue
            for t in srv.tools:
                idx[_safe_name(f"{srv.name}__{t.name}")[:64]] = (srv, t)
        return idx

    def openai_tools(self) -> list[dict]:
        out = []
        for fname, (srv, t) in self._index().items():
            params = t.inputSchema or {"type": "object", "properties": {}}
            params.setdefault("type", "object")
            params.setdefault("properties", {})
            out.append({"type": "function", "function": {
                "name": fname,
                "description": (t.description or t.name)[:1000],
                "parameters": params,
            }})
        return out

    def has(self, fname: str) -> bool:
        return fname in self._index()

    async def call(self, fname: str, args: dict) -> str:
        hit = self._index().get(fname)
        if not hit:
            return f"工具 {fname} 目前無法使用"
        srv, tool = hit
        if BLOCK_PRIVATE_URLS:
            for url in _urls_in(args):
                why = await asyncio.to_thread(check_url, url)
                if why:
                    return why
        try:
            res = await asyncio.wait_for(srv.session.call_tool(tool.name, args), CALL_TIMEOUT)
        except asyncio.TimeoutError:
            return f"工具 {fname} 執行逾時（{CALL_TIMEOUT} 秒）"
        except Exception as e:  # noqa: BLE001
            return f"工具 {fname} 執行失敗：{e}"
        parts = []
        for c in res.content:
            if getattr(c, "type", "") == "text":
                parts.append(c.text)
            elif getattr(c, "type", "") == "resource" and hasattr(c.resource, "text"):
                parts.append(c.resource.text)
            else:
                parts.append(f"[略過 {getattr(c, 'type', '?')} 內容]")
        text = "\n".join(parts) or "（工具沒有回傳內容）"
        return ("工具回報錯誤：" + text) if res.isError else text

    def status_lines(self) -> list[str]:
        lines = []
        for s in self.servers.values():
            if s.session:
                lines.append(f"✅ `{s.name}`：{len(s.tools)} 個工具")
            elif s.error:
                lines.append(f"❌ `{s.name}`：{s.error[:150]}")
            else:
                lines.append(f"⏳ `{s.name}`：啟動中（第一次要下載套件）")
        lines += [f"⏭️ `{n}`：{why}" for n, why in self.skipped.items()]
        return lines

    async def stop(self) -> None:
        for s in self.servers.values():
            s.stop.set()
        tasks = [s.task for s in self.servers.values() if s.task]
        if tasks:
            await asyncio.wait(tasks, timeout=10)
