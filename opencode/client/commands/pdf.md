---
# lab-opencode-command：由 install-client 安裝，重新安裝時會更新
description: PDF 工具：合併、取出頁、刪頁、旋轉、圖片轉 PDF、轉圖片、壓縮、Office 轉 PDF
---
使用者想對 PDF 做的事：$ARGUMENTS

依照使用者的需求，選一個 labdoc 指令執行（檔名一律用雙引號；頁碼用 1-3,5 這種格式，從 1 開始）：

| 需求 | 指令 |
|---|---|
| 合併多個 PDF（依順序，可夾圖片） | `labdoc pdf merge "a.pdf" "b.pdf" "c.jpg" -o "合併.pdf"` |
| 多張照片（收據、掃描）合成一個 PDF | `labdoc pdf fromimg "1.jpg" "2.jpg" -o "收據.pdf"` |
| 取出某幾頁成新檔 | `labdoc pdf pages "檔名.pdf" 1-3,5` |
| 刪掉某幾頁 | `labdoc pdf delete "檔名.pdf" 2,4` |
| 旋轉（90 / 180 / 270） | `labdoc pdf rotate "檔名.pdf" 90 --pages 2` |
| 每頁轉成 PNG 圖片 | `labdoc pdf topng "檔名.pdf"` |
| 壓縮檔案大小（上傳有限制時） | `labdoc pdf compress "檔名.pdf"` |
| Word / PPT / Excel 轉 PDF | `labdoc topdf "檔名.docx"` |
| PDF 轉 Word | `labdoc pdf2word "檔名.pdf"` |

步驟：
1. 檔名不確定時，先用 glob 找目前資料夾的檔案列給使用者確認；合併的順序也要跟使用者確認。
2. 執行指令。原始檔案不會被修改，結果會另存新檔。
3. 回報產生的檔案路徑（輸出中「已產生：」後面的路徑）。

注意：只用 labdoc，不要自己寫 Python 程式，也不要安裝其他套件。
