"""
agent.py — 工具呼叫迴圈：模型要用工具 → bot 執行（內建工具或 MCP）→ 結果餵回模型 → 直到模型給出答案。

模型服務不支援 tools 參數時，自動退回一般聊天（並記住，之後不再嘗試）。
"""

import asyncio
import json
import os
from typing import Awaitable, Callable

import llm_client

MAX_TOOL_ROUNDS = int(os.getenv("MAX_TOOL_ROUNDS", "8"))
TOOL_RESULT_MAX_CHARS = int(os.getenv("TOOL_RESULT_MAX_CHARS", "12000"))

# 內建工具：name -> (OpenAI function spec, 同步函式(**args) -> str)
Builtin = dict[str, tuple[dict, Callable[..., str]]]

_tools_supported = True


def tools_supported() -> bool:
    return _tools_supported


def _short(args: dict) -> str:
    for k in ("query", "q", "url", "expression", "title", "libraryName", "timezone"):
        if k in args:
            v = str(args[k])
            return v if len(v) <= 60 else v[:57] + "…"
    return ""


async def run(messages: list[dict], mcp=None, builtins: Builtin | None = None,
              on_tool: Callable[[str, str], Awaitable[None]] | None = None,
              use_tools: bool = True) -> str:
    """跑完整個工具迴圈，回傳最終答案文字。on_tool(工具名, 參數摘要) 給 Discord 顯示進度。"""
    global _tools_supported
    builtins = builtins or {}
    msgs = list(messages)

    def tool_specs() -> list[dict]:
        if not (use_tools and _tools_supported):
            return []
        specs = [spec for spec, _ in builtins.values()]
        if mcp:
            specs += mcp.openai_tools()
        return specs

    for round_ in range(MAX_TOOL_ROUNDS + 1):
        # 最後一輪不給工具，逼模型用手上的資料作答
        tools = tool_specs() if round_ < MAX_TOOL_ROUNDS else []
        try:
            msg = await asyncio.to_thread(llm_client.chat_message, msgs, tools=tools or None)
        except llm_client.ToolsUnsupported as e:
            print(f"[工具] 模型服務不支援 tools，改回一般聊天：{e}")
            _tools_supported = False
            msg = await asyncio.to_thread(llm_client.chat_message, msgs)

        calls = msg.get("tool_calls") or []
        if not calls:
            return llm_client.clean(msg.get("content"))

        # 把模型這一步原樣放回對話（Kimi 等思考模型需要保留 reasoning_content 才能接續）
        assistant = {"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls}
        if msg.get("reasoning_content"):
            assistant["reasoning_content"] = msg["reasoning_content"]
        msgs.append(assistant)

        for call in calls:
            fn = call.get("function", {})
            name = fn.get("name", "")
            try:
                args = json.loads(fn.get("arguments") or "{}")
                if not isinstance(args, dict):
                    raise ValueError("參數必須是 JSON 物件")
            except (json.JSONDecodeError, ValueError) as e:
                result = f"參數不是合法的 JSON：{e}"
            else:
                if on_tool:
                    try:
                        await on_tool(name, _short(args))
                    except Exception:  # noqa: BLE001  顯示進度失敗不影響回答
                        pass
                result = await _exec(name, args, mcp, builtins)
            if len(result) > TOOL_RESULT_MAX_CHARS:
                result = result[:TOOL_RESULT_MAX_CHARS] + f"\n…（內容過長，已截斷，原長 {len(result)} 字）"
            msgs.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": result})

    return "（工具呼叫次數過多，沒有得到答案，請換個問法）"


async def _exec(name: str, args: dict, mcp, builtins: Builtin) -> str:
    try:
        if name in builtins:
            return str(await asyncio.to_thread(builtins[name][1], **args))
        if mcp and mcp.has(name):
            return await mcp.call(name, args)
        return f"沒有名為 {name} 的工具"
    except Exception as e:  # noqa: BLE001
        return f"工具 {name} 執行失敗：{e}"
