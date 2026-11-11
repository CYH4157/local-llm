"""
selftest.py — 不用開 Discord，直接檢查工具功能。

    python selftest.py            啟動所有 MCP server、列出工具、每個 server 試呼叫一次
    python selftest.py --llm      再用 .env 的模型服務實際問一題，確認模型會呼叫工具（例如 NCHC Kimi）
    python selftest.py --llm "問題"   自訂問題
"""

import asyncio
import os
import sys

from dotenv import load_dotenv

HERE = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(HERE, ".env"), override=True)

import agent  # noqa: E402
import llm_client  # noqa: E402
import mcp_client  # noqa: E402

# 每個 server 拿一個不花錢、不改東西的工具試呼叫（找不到就略過）
SAMPLES = {
    "time__get_current_time": {"timezone": "Asia/Taipei"},
    "calculator__calculate": {"expression": "2**10 + 3*7"},
    "fetch__fetch": {"url": "https://example.com", "max_length": 300},
    "wikipedia__search_wikipedia": {"query": "Taiwan", "limit": 2},
    "arxiv__search_papers": {"query": "large language model tool use", "max_results": 1},
    "memory__read_graph": {},
    "context7__resolve-library-id": {"libraryName": "discord.py", "query": "discord.py"},
}


async def main():
    mcp = mcp_client.MCPManager()
    await mcp.start()
    print("等待 MCP server 就緒（第一次要下載套件，可能要 1~3 分鐘）…")
    await mcp.wait_ready()
    print("\n".join(mcp.status_lines()))

    names = [t["function"]["name"] for t in mcp.openai_tools()]
    print(f"\n共 {len(names)} 個 MCP 工具：{', '.join(names)}\n")
    for name, args in SAMPLES.items():
        if name in names:
            out = await mcp.call(name, args)
            print(f"--- {name} → {out[:200]!r}")
    print("--- 內網防護：", await mcp.call("fetch__fetch", {"url": "http://127.0.0.1:8000/v1/models"})
          if "fetch__fetch" in names else "（沒有 fetch）")

    if "--llm" in sys.argv:
        rest = [a for a in sys.argv[1:] if a != "--llm"]
        q = rest[0] if rest else "今天台灣時間幾點？另外請算 123456 * 789，並用維基百科查一下國家高速網路與計算中心是什麼。"
        print(f"\n=== 模型實測：{llm_client.BASE_URL}  思考={'關' if llm_client.disable_thinking() else '開'}")
        print(f"問題：{q}")
        builtins = {}
        try:
            import discord_bot  # noqa: F401  需要 DISCORD_BOT_TOKEN；沒有就不測內建 web_search
            builtins = discord_bot.BUILTIN_TOOLS
        except SystemExit:
            pass

        async def on_tool(name, brief):
            print(f"  🔧 {name} {brief}")

        msgs = [{"role": "system", "content": "你是助理，用台灣繁體中文回答。需要時使用工具。"},
                {"role": "user", "content": q}]
        ans = await agent.run(msgs, mcp=mcp, builtins=builtins, on_tool=on_tool)
        print(f"\n回答：\n{ans}")
        if not agent.tools_supported():
            print("\n⚠️ 模型服務拒絕 tools 參數：這個 gateway / 模型沒有開 tool calling。")
        elif "<|tool_call" in ans or "functions." in ans:
            print("\n⚠️ 回答裡有原始的工具呼叫標記：gateway 沒有解析 tool call（vLLM 需 --enable-auto-tool-choice --tool-call-parser）。")

    await mcp.stop()


if __name__ == "__main__":
    asyncio.run(main())
