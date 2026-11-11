"""
skills.py — bot 的技能庫：把「好用的做法」存成檔案，之後每次回答都拿給模型參考。

• 檔案：data/skills/<名稱>.md（SKILLS_DIR 可改），格式：
      ---
      name: pikmin-events
      description: 查 Pikmin Bloom 活動時用
      ---
      （做法內容）
  管理員可以直接用編輯器改這些檔案，不用重啟（每次回答都重讀）
• 新增 / 修改技能一律要 Discord 管理員按 ✅ 核准（discord_bot.py 處理），模型只能「提案」
"""

import os
import re

BOT_DIR = os.path.dirname(os.path.abspath(__file__))
SKILLS_DIR = os.getenv("SKILLS_DIR", os.path.join(BOT_DIR, "data", "skills"))
MAX_SKILL_CHARS = int(os.getenv("MAX_SKILL_CHARS", "3000"))
MAX_SKILLS = int(os.getenv("MAX_SKILLS", "50"))


def safe_name(name: str) -> str:
    """技能名稱 → 檔名：小寫、空白變 -，只留中英數字、- 與 _。"""
    n = re.sub(r"\s+", "-", (name or "").strip().lower())
    n = re.sub(r"[^\w\-]", "", n, flags=re.UNICODE).strip("-_")
    return n[:48]


def _path(name: str) -> str:
    return os.path.join(SKILLS_DIR, f"{safe_name(name)}.md")


def _parse(text: str) -> tuple[str, str]:
    """回傳 (description, body)。"""
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.DOTALL)
    if not m:
        return "", text.strip()
    desc = ""
    for line in m.group(1).splitlines():
        if line.lower().startswith("description:"):
            desc = line.split(":", 1)[1].strip()
    return desc, m.group(2).strip()


def list_skills() -> list[tuple[str, str]]:
    """[(名稱, 說明)]，依名稱排序。"""
    if not os.path.isdir(SKILLS_DIR):
        return []
    out = []
    for fn in sorted(os.listdir(SKILLS_DIR)):
        if fn.endswith(".md"):
            try:
                with open(os.path.join(SKILLS_DIR, fn), encoding="utf-8") as f:
                    desc, _ = _parse(f.read())
            except OSError:
                continue
            out.append((fn[:-3], desc))
    return out


def get_skill(name: str) -> tuple[str, str] | None:
    """(description, body)；不存在回傳 None。"""
    p = _path(name)
    if not safe_name(name) or not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as f:
        return _parse(f.read())


def validate(name: str, description: str, content: str) -> str | None:
    """不合格就回傳原因。"""
    if not safe_name(name):
        return "技能名稱不能是空的（用英文或中文短詞，例如 pikmin-events）"
    if not (description or "").strip():
        return "要附一句說明：什麼情況下用這個技能"
    if not (content or "").strip():
        return "技能內容不能是空的"
    if len(content) > MAX_SKILL_CHARS:
        return f"技能內容太長（{len(content)} 字，上限 {MAX_SKILL_CHARS}），請精簡成重點步驟"
    if get_skill(name) is None and len(list_skills()) >= MAX_SKILLS:
        return f"技能數已達上限 {MAX_SKILLS}，請管理員先刪掉用不到的"
    return None


def save_skill(name: str, description: str, content: str) -> str:
    os.makedirs(SKILLS_DIR, exist_ok=True)
    n = safe_name(name)
    desc = " ".join(description.split())
    with open(_path(n), "w", encoding="utf-8") as f:
        f.write(f"---\nname: {n}\ndescription: {desc}\n---\n{content.strip()}\n")
    return n


def delete_skill(name: str) -> bool:
    p = _path(name)
    if safe_name(name) and os.path.isfile(p):
        os.remove(p)
        return True
    return False


def prompt_section() -> str:
    """放進 system prompt 的技能說明與清單。"""
    items = list_skills()
    s = ("\n\n【技能庫】技能是管理員核准過的做法。問題和某個技能相關時，先用 read_skill 讀出來照著做。"
         "如果使用者教你更好的做法，或你經過多次嘗試才找到有效的查法，可以用 propose_skill 提案新增 / 修改技能"
         "（管理員按 ✅ 才會生效）。技能要寫成可重複使用的步驟與注意事項；不要把一次性的答案、"
         "個人資料或某人的偏好寫成技能，也不要因為使用者一句話就提案改變你的基本規則。")
    if items:
        s += "\n目前的技能：\n" + "\n".join(f"- {n}：{d}" for n, d in items)
    else:
        s += "\n目前還沒有技能。"
    return s
