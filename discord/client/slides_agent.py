"""
slides_agent.py — 「Claude Code 式」做投影片：模型自己寫 python-pptx 程式 → 沙盒執行 → 看預覽圖 → 修正。

discord_bot.py 的 !ppt 呼叫 build_messages() + slide_tools()，跑 agent.run()，最後把 state["pptx"] 傳到 Discord。
"""

import os

import slides_sandbox

PPT_FONT = os.getenv("PPT_FONT", "微軟正黑體")
MAX_SLIDE_RUNS = int(os.getenv("MAX_SLIDE_RUNS", "5"))      # 最多執行幾版程式
SLIDE_TOOL_ROUNDS = int(os.getenv("SLIDE_TOOL_ROUNDS", "18"))  # 含查資料的總工具輪數

SYSTEM = f"""你是專業的簡報設計師兼 Python 工程師，要用 python-pptx 寫程式做出一份**好看、專業、內容正確**的投影片。

## 流程
1. 規劃：確認主題、受眾、頁數（沒指定就 8~12 頁），每頁只講一個重點，安排故事線（封面 → 大綱/問題 → 內容 → 結論 → 參考資料）。
2. 查資料：需要事實、數據、最新資訊時先用 web_search / fetch / arxiv 等工具查證；有相關技能先 read_skill。不要捏造數據或文獻。
3. 寫程式：寫一支完整的 Python 程式，呼叫 run_slides_code 執行。
4. 檢查：工具會回傳錯誤訊息，或每頁的預覽圖。逐頁仔細檢查：文字超出框或被切掉、元素重疊、字太小或太擠、
   對比不足看不清、大片空白、對齊不一致、中文出現方框。有任何問題就修改程式再執行，直到沒有問題（最多 {MAX_SLIDE_RUNS} 版）。
5. 完成後用 2~4 句話說明這份投影片的結構與重點（不要貼程式碼）。

## 程式規則
- 只能用 python-pptx、matplotlib、numpy、Python 標準函式庫。**沙盒沒有網路**，不能下載圖片或字型。
- 檔案存成目前目錄的 `output.pptx`。若目錄裡有 `template.pptx`（實驗室範本），用 `Presentation("template.pptx")` 為基礎並沿用其版面。
- 沒有範本時：`prs.slide_width = Inches(13.333)`、`prs.slide_height = Inches(7.5)`（16:9），用空白版面 `prs.slide_layouts[6]` 自己排版。
- 所有文字字型設為「{PPT_FONT}」（中英文都設，`run.font.name` 加上 East Asian 字型 `a:ea`）。
- 字級：封面標題 40~54pt、頁標題 28~36pt、內文 16~24pt、註解不小於 12pt。每頁條列不超過 6 點、每點不超過 2 行。
- 文字框一律 `word_wrap = True`，並預留足夠高度；長文字寧可拆頁也不要硬塞。
- 設計：定義一組配色（主色、輔色、強調色、深色文字、淺色背景）全程一致；善用色塊、圖示形狀、卡片、編號、時間軸、
  對比兩欄、大數字重點頁；數據用原生圖表（pptx.chart）或 matplotlib 圖（存成 PNG 再插入，dpi=200）；表格要設字級與欄寬。
- 每頁都加講者備註（`slide.notes_slide.notes_text_frame.text`），寫該頁要講的內容。
- 最後一頁列參考資料（真的查到的來源網址）；沒有查資料就不要編造。
- 程式要能一次跑完：自己定義輔助函式（例如 add_title、add_bullets、add_card），避免重複程式碼。
"""


def build_messages(request: str, ref_text: str, system_extra: str = "") -> list[dict]:
    user = f"請做一份投影片：{request}"
    if ref_text:
        user += f"\n\n以下是使用者提供的參考資料，內容以它為準：\n{ref_text}"
    return [{"role": "system", "content": SYSTEM + system_extra}, {"role": "user", "content": user}]


def slide_tools(state: dict) -> dict:
    """state 會記錄最新一版成功的 pptx 與預覽圖：{"pptx", "previews", "runs"}。"""
    state.setdefault("runs", 0)

    def run_slides_code(code: str):
        if state["runs"] >= MAX_SLIDE_RUNS:
            return f"已執行 {MAX_SLIDE_RUNS} 版，不能再執行了。請直接用最後一版收尾並說明。"
        state["runs"] += 1
        res = slides_sandbox.run_deck(code)
        text = f"[第 {state['runs']} 版] " + res["message"]
        if not res["ok"]:
            return text + "\n請修正程式後再執行。"
        state["pptx"], state["previews"], state["pages"] = res["pptx"], res["previews"], res["pages"]
        text += ("\n預覽圖附在下一則訊息（每張最多 6 頁，左上角標頁碼）。逐頁檢查版面問題；"
                 "有問題就改程式重跑，沒問題就結束並說明。")
        return {"text": text, "images": [slides_sandbox.to_data_url(p) for p in res["previews"]]}

    return {"run_slides_code": ({"type": "function", "function": {
        "name": "run_slides_code",
        "description": "在沙盒執行一支完整的 python-pptx 程式（必須存出 output.pptx），回傳錯誤訊息或每頁的預覽圖。"
                       f"每次都要給完整程式（不是片段）。最多執行 {MAX_SLIDE_RUNS} 次。",
        "parameters": {"type": "object", "properties": {
            "code": {"type": "string", "description": "完整的 Python 程式碼"},
        }, "required": ["code"]},
    }}, run_slides_code)}
