"""Benchmark the running vLLM model with the lab's real workloads. Stdlib only.

usage: python3 bench.py LABEL OUTFILE
"""
import json
import os
import re
import sys
import threading
import time
import urllib.request

label, outfile = sys.argv[1], sys.argv[2]
env = {}
for line in open(os.path.expanduser("~/vllm-server/vllm.env")):
    m = re.match(r'^(\w+)="?(.*?)"?\s*$', line)
    if m:
        env[m.group(1)] = m.group(2)
URL = f"http://127.0.0.1:{env.get('SERVE_PORT', '8000')}/v1/chat/completions"
KEY, MODEL = env["SERVE_API_KEY"], env["SERVE_NAME"]
out = []


def log(s=""):
    print(s, flush=True)
    out.append(s)


def chat(messages, max_tokens, tools=None, timeout=900):
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens, "temperature": 0.3}
    if tools:
        body["tools"], body["tool_choice"] = tools, "auto"
    req = urllib.request.Request(URL, json.dumps(body).encode(), {
        "Content-Type": "application/json", "Authorization": f"Bearer {KEY}"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)
    return resp, time.time() - t0


def text(resp):
    return (resp["choices"][0]["message"].get("content") or "").strip()


log(f"## {label} — {MODEL} (max-len {env.get('SERVE_MAX_LEN')})")

# 1. single-user speed
r, dt = chat([{"role": "user", "content": "Write a Python function that checks if a number is prime, with a docstring."}], 300)
n = r["usage"]["completion_tokens"]
log(f"- 1 生成速度（單人）: {n} tokens / {dt:.1f}s = **{n / dt:.1f} tok/s**")

# 2. long context (~20k tokens) with a fact hidden in the middle
paras = [f"Paragraph {i}: routine notes about lab equipment maintenance, cleaning schedules and safety checks." for i in range(1100)]
paras[550] = "IMPORTANT NOTE: the secret passphrase for the lab server is BLUE-DOLPHIN-42."
try:
    r, dt = chat([{"role": "user", "content": "\n".join(paras) + "\n\nWhat is the secret passphrase for the lab server? Answer with the passphrase only."}], 30)
    ok = "BLUE-DOLPHIN-42" in text(r)
    log(f"- 2 長文件: {r['usage']['prompt_tokens']} tokens 輸入，{dt:.1f}s，找到隱藏資訊: **{'是' if ok else '否'}**（回答：{text(r)[:40]}）")
except Exception as e:
    log(f"- 2 長文件: **失敗** {e}")

# 3. tool calling (what opencode relies on)
tools = [{"type": "function", "function": {"name": "read", "description": "Read a file from disk",
          "parameters": {"type": "object", "properties": {"filePath": {"type": "string"}}, "required": ["filePath"]}}}]
r, dt = chat([{"role": "user", "content": "Read the file src/main.py"}], 200, tools)
tc = r["choices"][0]["message"].get("tool_calls") or []
calls = [(t["function"]["name"], t["function"]["arguments"]) for t in tc]
log(f"- 3 工具呼叫: **{'成功' if calls else '失敗'}** {calls}（{dt:.1f}s）")

# 4. five users at once
results = []


def worker(i):
    try:
        rr, d = chat([{"role": "user", "content": f"Write a short poem (about 8 lines) about the ocean, variation {i}."}], 200)
        results.append((rr["usage"]["completion_tokens"], d))
    except Exception as e:
        results.append((0, 0, str(e)))


t0 = time.time()
ths = [threading.Thread(target=worker, args=(i,)) for i in range(5)]
[t.start() for t in ths]
[t.join() for t in ths]
wall = time.time() - t0
total = sum(x[0] for x in results)
slowest = max(x[1] for x in results)
log(f"- 4 五人同時: 總共 {total} tokens / {wall:.1f}s = **{total / wall:.1f} tok/s 總吞吐**，最慢的人等 {slowest:.1f}s")

# 5. Chinese explanation (homework use)
r, dt = chat([{"role": "user", "content": "請用繁體中文、150字以內，解釋什麼是梯度下降，並舉一個生活化的例子。"}], 400)
log(f"- 5 中文解釋（{dt:.1f}s）:")
log("  > " + text(r).replace("\n", "\n  > "))

# 6. coding
r, dt = chat([{"role": "user", "content": "寫一個 Python 函式 most_common(items)，回傳 list 中出現次數最多的元素（同票時回傳最早出現的），附 docstring 和兩個 assert 測試。只輸出程式碼。"}], 500)
log(f"- 6 寫程式（{dt:.1f}s）:")
log("```python\n" + re.sub(r"^```\w*\n?|```$", "", text(r).strip(), flags=re.M).strip() + "\n```")

open(os.path.expanduser(outfile), "w").write("\n".join(out) + "\n")
