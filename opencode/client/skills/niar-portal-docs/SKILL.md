---
name: niar-portal-docs
description: 在國研院 portal.niar.org.tw 文件庫快速尋找並下載採購表單（如 30 萬元以下點驗及簽認紀錄表）到 D:\claude-code。含已知資料夾與檔案 ID，不必從頭摸索。
---

# NIAR Portal 文件下載

從 https://portal.niar.org.tw 下載文件。此站是 Liferay + React 前端，**API 路線全部無效**（JSONWS / headless-delivery 回 403、headless-admin-content 回 404），一律用瀏覽器真實導覽。

開始前先用 `skill` 工具載入 `browser` skill，所有瀏覽器操作透過 `execute`（Code Mode）呼叫 `tools.browser.*`。

## 0. 下載目的地

一律放到 `D:\claude-code`。

## 1. 登入（第一步，必做）

1. `tools.browser.tabs.open` 開 `https://portal.niar.org.tw/home`。
2. 用 `evaluate`（見下方瀏覽器要點）檢查是否已登入：頁面上找「登入」連結或使用者頭像。
3. 未登入就**請使用者自己在瀏覽器分頁輸入 SSO 帳號密碼**，不要代打帳密。等使用者說登入完成再繼續。
4. Session 約數小時會過期；若後續頁面變回登入畫面，回到此步。

## 2. 直接命中：已知 ID 清單（優先使用）

目標站台：**國網中心（NCHC）文件庫**，`https://portal.niar.org.tw/web/nchc/docmanage`，documents groupId = `11130`。

資料夾樹：`行政 (1534059)` → `1.請採購 (1534085)` → `2.請購表單 (1729502)`

已知 fileEntryId（30 萬以下表單都在 `2.請採購` 資料夾）：

| 檔名 | fileEntryId |
|---|---|
| 07.點驗及簽認紀錄表(30萬以下).docx | 4024948 |
| 01.30萬以下自辦採購說明 | 4696323 |
| 06.查驗測試紀錄表(30萬以上) | 1537998 |

fileEntryId 可能因檔案更新而改版失效；失效時走第 3 節的資料夾瀏覽，從 `2.請購表單 (1729502)` 重新找 ID 並更新此表。

## 3. URL 模式

- 瀏覽資料夾：
  `https://portal.niar.org.tw/web/nchc/docmanage?p_p_id=com_liferay_document_library_web_portlet_DLPortlet&_com_liferay_document_library_web_portlet_DLPortlet_folderId={folderId}`
- 檢視單一檔案（含下載按鈕）：同上 URL 再加
  `&_com_liferay_document_library_web_portlet_DLPortlet_mvcRenderCommandName=%2Fdocument_library%2Fview_file_entry&_com_liferay_document_library_web_portlet_DLPortlet_fileEntryId={fileEntryId}`
- 下載連結形式（點檔案頁的下載按鈕取得，不用手組）：
  `https://portal.niar.org.tw/documents/11130/{folderId}/{檔名}/{uuid}?t={ts}&download=true`

## 4. 搜尋教訓（省時間的關鍵）

- **不要用站內全域搜尋**：30 萬以下表單搜不到，只能逐層瀏覽資料夾樹。
- **命名陷阱**：30 萬元以上版叫「查驗測試紀錄表」，30 萬元以下版叫「**點驗及簽認紀錄表**」。使用者說「查驗紀錄表」且是 30 萬以下，目標就是 `07.點驗及簽認紀錄表(30萬以下)`。
- niar 主站台的 8 個單位資料夾只有 30 萬以上版；30 萬以下版只在 NCHC 站台的 `2.請購表單` 資料夾。

## 5. 下載落地四步驟

1. 在檔案檢視頁用 `tools.browser.click` 點下載按鈕/連結（React 渲染後 DOM 才有，先等 2.5–5 秒）。
2. `tools.browser.files.list()` 找到剛下載的檔（依時間排序最新的）。
3. `tools.browser.files.get({ path })` 確認，取得 server-local path（上限 5 MiB）。
4. 在 Code Mode **外**用 `shell` 工具複製落地：
   `Copy-Item '<server-local path>' 'D:\claude-code\'`

## 6. 驗證

- `shell` 讀前幾個 byte 確認標頭：`.docx/.xlsx/.zip` 是 `PK`（0x50 0x4B），並檢查檔案大小合理（數萬 byte 以上）。
- 落地後立刻讀取若失敗，可能是瀏覽器短暫鎖定，等 1–2 秒重試。
- PowerShell 顯示中文檔名會是亂碼（檔案本身沒問題）；要正常顯示先設 `[Console]::OutputEncoding=[Text.Encoding]::UTF8`。

## 瀏覽器操作要點（React SPA）

- `evaluate` 的 script 不能有頂層 `return`，用 IIFE 包裝：`( () => { ... return x } )()`。
- 等待渲染/延遲：`await new Promise(s => setTimeout(s, 3000))`，一般等 2.5–5 秒再讀 DOM。
- 讀不到元素先確認分頁 URL 正確、已登入、渲染已完成，再重試。
