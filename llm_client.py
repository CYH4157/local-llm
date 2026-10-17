"""
llm_client.py — 呼叫 OpenAI 相容 API（llama-swap → vLLM）。

llama-swap 依 request 裡的 "model" 名稱自動啟動 / 切換對應的 vLLM，
所以「換模型」對 bot 來說只是改一個字串。
"""

import json
import os
import re

import requests

BASE_URL = os.getenv("LLM_BASE_URL", "http://127.0.0.1:8080/v1").strip().rstrip("/")
# /v1 前面的根網址，用來打 llama-swap 自己的管理 API（/running 等）
ROOT_URL = re.sub(r"/v1$", "", BASE_URL)
API_KEY  = os.getenv("LLM_API_KEY", "").strip()
# 第一次載入模型（含下載 / 編譯）可能要好幾分鐘，timeout 給寬一點
TIMEOUT  = int(os.getenv("LLM_TIMEOUT", "900"))

_THINK_RE = re.compile(r"<think>.*?</think>\s*", re.DOTALL)


def _headers() -> dict:
    return {"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}


def list_models() -> list[dict]:
    """回傳 [{id, name, description}]，來源是 llama-swap 設定檔裡的 models。"""
    r = requests.get(f"{BASE_URL}/models", headers=_headers(), timeout=15)
    r.raise_for_status()
    return [
        {"id": m["id"], "name": m.get("name", ""), "description": m.get("description", "")}
        for m in r.json().get("data", [])
    ]


def running_models() -> list[str]:
    """目前已載入 GPU 的模型（llama-swap /running）；失敗回空陣列。"""
    try:
        r = requests.get(f"{ROOT_URL}/running", headers=_headers(), timeout=10)
        r.raise_for_status()
        return [m.get("model", "") for m in r.json().get("running", [])]
    except Exception:  # noqa: BLE001
        return []


def chat(model: str, messages: list[dict], max_tokens: int | None = None,
         temperature: float = 0.7, response_format: dict | None = None) -> str:
    """
    max_tokens=None → 不指定，vLLM 會用「上下文長度 − 輸入長度」當上限。
    這樣不會因為 輸入+max_tokens 超過 --max-model-len 而被拒絕。
    """
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        # Qwen3 系列預設會先「思考」，日常任務關掉比較快（其他模型會忽略此參數）
        "chat_template_kwargs": {"enable_thinking": False},
    }
    if max_tokens:
        payload["max_tokens"] = max_tokens
    if response_format:
        payload["response_format"] = response_format
    r = requests.post(f"{BASE_URL}/chat/completions", json=payload,
                      headers=_headers(), timeout=TIMEOUT)
    if r.status_code >= 400:
        raise RuntimeError(f"LLM API {r.status_code}: {r.text[:300]}")
    content = r.json()["choices"][0]["message"].get("content") or ""
    return _THINK_RE.sub("", content).strip()


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


def chat_json(model: str, messages: list[dict], schema: dict, name: str,
              max_tokens: int | None = None) -> dict:
    """
    要求模型輸出符合 schema 的 JSON。
    vLLM 的 guided decoding 會「強制」輸出合法 JSON；
    若後端不支援 json_schema，就退回一般模式再自己解析。
    """
    fmt = {"type": "json_schema", "json_schema": {"name": name, "schema": schema}}
    try:
        text = chat(model, messages, max_tokens=max_tokens, temperature=0.5,
                    response_format=fmt)
    except RuntimeError as e:
        if "response_format" not in str(e) and "json_schema" not in str(e):
            raise
        text = chat(model, messages, max_tokens=max_tokens, temperature=0.5)
    return _extract_json(text)
