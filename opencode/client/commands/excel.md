---
# lab-opencode-command：由 install-client 安裝，重新安裝時會更新
description: 做 Excel 表格（名單、清單、統計、比較表）
---
做一份 Excel 表格。需求或資料：$ARGUMENTS

步驟：
1. 資料在檔案裡時，用 `labdoc read "檔名"` 讀（.txt / .md / .csv 用 read 工具）。
2. 用 write 工具寫成 Markdown 檔（例如 `報名名單.md`）。一個表格 = 一個工作表，表格上方的標題就是工作表名稱：

```markdown
## 工作表名稱
| 欄位一 | 欄位二 | 金額 |
|---|---|---|
| A | B | 1200 |
```

   規則：
   - 第一列是欄位名稱；每一列欄位數要一樣，沒有資料就留空。
   - 數字只寫數字（`1200`，不要寫「一千二」）；日期寫 `2026-10-24`；電話、學號照原樣寫。
   - **不要自己加總或計算**：需要合計時，執行時加 `--total`，Excel 會用公式算。
   - 只整理使用者給的資料，不要自己補資料。
3. 執行：`labdoc excel "報名名單.md"`（需要合計：`labdoc excel "報名名單.md" --total`）
4. 回報 .xlsx 路徑和工作表名稱。

注意：只用 labdoc 產生 Excel，不要自己寫 openpyxl 程式。
