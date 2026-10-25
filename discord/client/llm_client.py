"""
llm_client.py — 呼叫實驗室主機上的 vLLM（server/vllm 架設的那台，OpenAI 相容 API）。

• 模型：自動使用 vLLM 目前載入的模型（/v1/models），主機用 vllmctl 換模型後 bot 不用改設定
• 金鑰：.env 的 LLM_API_KEY 留空時，自動讀主機的 ~/vllm-server/vllm.env 裡的 SERVE_API_KEY：
        Ubuntu 伺服器（例如 H200）直接讀檔；Windows 筆電從 WSL 讀。
        主機執行 vllmctl new-key 換金鑰後，遇到 401 會自動重讀一次
"""

import json
import os
import re
import subprocess
import time

import requests

BASE_URL   = os.getenv("LLM_BASE_URL", "http://127.0.0.1:8000/v1").strip().rstrip("/")
WSL_DISTRO = os.getenv("WSL_DISTRO", "Ubuntu").strip() or "Ubuntu"   # 只有 Windows 用
VLLM_ENV   = os.path.expanduser(os.getenv("VLLM_ENV_FILE", "~/vllm-server/vllm.env"))   # 只有 Linux 用
# 第一次載入模型、或多人同時使用時可能較慢，timeout 給寬一點
TIMEOUT    = int(os.getenv("LLM_TIMEOUT", "600"))

_THINK_RE = re.compile(r"<think>.*?</think>\s*", re.DOTALL)
_api_key = os.getenv("LLM_API_KEY", "").strip()
_model_cache: tuple[float, dict] | None = None   # (時間, 模型資訊)
MODEL_CACHE_SEC = 60


class AuthError(RuntimeError):
    pass


def read_key_from_host() -> str:
    """讀 vLLM 主機的金鑰：Linux 直接讀 vllm.env；Windows 從 WSL 讀（跟 opencode 的 install-client 一樣）。"""
    if os.name != "nt":
        try:
            with open(VLLM_ENV, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r'^\s*SERVE_API_KEY="?([^"\s]*)"?\s*$', line)
                    if m:
                        return m.group(1)
        except OSError:
            pass
        return ""
    try:
        out = subprocess.run(
            ["wsl.exe", "-d", WSL_DISTRO, "-e", "bash", "-c",
             ". ~/vllm-server/vllm.env 2>/dev/null; printf %s \"$SERVE_API_KEY\""],
            capture_output=True, timeout=30,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),   # 背景執行時不跳出視窗
        )
        return out.stdout.decode("utf-8", errors="ignore").strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _key(refresh: bool = False) -> str:
    global _api_key
    if refresh or not _api_key:
        k = read_key_from_host()
        if k:
            _api_key = k
    return _api_key


def _request(method: str, path: str, timeout: int, **kw) -> requests.Response:
    """送出請求；401 時重讀主機金鑰再試一次（vllmctl new-key 換過金鑰的情況）。"""
    for attempt in (0, 1):
        headers = {"Authorization": f"Bearer {_key(refresh=attempt == 1)}"}
        r = requests.request(method, f"{BASE_URL}{path}", headers=headers, timeout=timeout, **kw)
        if r.status_code != 401:
            return r
    raise AuthError("401 Unauthorized：API 金鑰錯誤")


def list_models() -> list[dict]:
    """回傳 [{id, max_model_len}]；vLLM 一次只載入一個模型。"""
    r = _request("GET", "/models", timeout=15)
    r.raise_for_status()
    return [{"id": m["id"], "max_model_len": m.get("max_model_len")}
            for m in r.json().get("data", [])]


def current_model(refresh: bool = False) -> dict:
    """目前 vLLM 載入的模型（快取 60 秒）。"""
    global _model_cache
    if not refresh and _model_cache and time.time() - _model_cache[0] < MODEL_CACHE_SEC:
        return _model_cache[1]
    models = list_models()
    if not models:
        raise RuntimeError("vLLM 沒有回傳任何模型")
    _model_cache = (time.time(), models[0])
    return models[0]


def chat(messages: list[dict], max_tokens: int | None = None,
         temperature: float = 0.7, response_format: dict | None = None) -> str:
    """
    max_tokens=None → 不指定，vLLM 會用「上下文長度 − 輸入長度」當上限，
    不會因為 輸入 + max_tokens 超過 --max-model-len 而被拒絕。
    """
    for attempt in (0, 1):
        payload = {
            "model": current_model(refresh=attempt == 1)["id"],
            "messages": messages,
            "temperature": temperature,
            # Qwen3 思考型模型關掉思考，日常任務快很多（其他模型會忽略此參數）
            "chat_template_kwargs": {"enable_thinking": False},
        }
        if max_tokens:
            payload["max_tokens"] = max_tokens
        if response_format:
            payload["response_format"] = response_format
        r = _request("POST", "/chat/completions", timeout=TIMEOUT, json=payload)
        # 404 = 主機剛換了模型、快取的名字已不存在 → 重抓一次模型名稱
        if r.status_code == 404 and attempt == 0:
            continue
        if r.status_code >= 400:
            raise RuntimeError(f"LLM API {r.status_code}: {r.text[:300]}")
        content = r.json()["choices"][0]["message"].get("content") or ""
        return _THINK_RE.sub("", content).strip()
    raise RuntimeError("找不到 vLLM 目前的模型")


def _extract_json(text: str):
    """模型偶爾會包 ```json ...``` 或多講話；抓出第一個完整 JSON 物件。"""
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            return json.loads(text[start:end + 1])
        raise


def is_context_error(e: Exception) -> bool:
    s = str(e).lower()
    return "context length" in s or "max_model_len" in s or "too long" in s


def chat_json(messages: list[dict], schema: dict, name: str,
              max_tokens: int | None = None) -> dict:
    """
    要求模型輸出符合 schema 的 JSON。
    vLLM 的結構化輸出會「強制」產生合法 JSON；萬一不支援就退回一般模式自己解析。
    """
    fmt = {"type": "json_schema", "json_schema": {"name": name, "schema": schema}}
    try:
        text = chat(messages, max_tokens=max_tokens, temperature=0.5, response_format=fmt)
    except RuntimeError as e:
        if "response_format" not in str(e) and "json_schema" not in str(e):
            raise
        text = chat(messages, max_tokens=max_tokens, temperature=0.5)
    return _extract_json(text)
