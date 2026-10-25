---
# lab-opencode-command：由 install-client 安裝，重新安裝時會更新
description: PDF 轉 Word（可編輯、保留版面）
---
把 PDF 轉成可編輯的 Word 檔。使用者給的檔案或說明：$ARGUMENTS

步驟：
1. 沒有給檔名，或檔名不確定時：用 glob 找目前資料夾的 `**/*.pdf`，列出來請使用者選，不要自己猜。
2. 執行（檔名一律用雙引號包起來）：
   - 整份：`labdoc pdf2word "檔名.pdf"`
   - 只轉部分頁：`labdoc pdf2word "檔名.pdf" --pages 1-3,5`
3. 回報產生的 Word 檔路徑（輸出最後一行「已產生：」後面的路徑）。
4. 輸出有「讀不到文字」的注意訊息時，告訴使用者這是掃描檔，轉出來的 Word 只有圖片、不能改字。

注意：只用 labdoc 轉檔，不要自己寫 Python 程式，也不要安裝其他套件。
