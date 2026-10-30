# opencode skills

install-client 會把這裡選好的資料夾複製到 `~/.config/opencode/skills/<名稱>/`，每個專案都能用。
uninstall-client 只會刪掉 install-client 裝的（有 `.lab-opencode-skill` 標記檔），自己裝的保留。

## 其他 skill（逐一詢問）

HyperFrames 以外的每個資料夾，install-client 開始時都會顯示 `description` 並逐一問要不要裝。
不想被問：`-Skills a,b`（`--skills a,b`，`all`＝全部）直接裝，或 `-SkipSkills`（`--skip-skills`）都不裝。

| skill | 用途 |
|---|---|
| niar-portal-docs | 在國研院 portal 文件庫找並下載採購表單（如 30 萬元以下點驗及簽認紀錄表） |

新增 skill：建立 `<名稱>/SKILL.md`，開頭 frontmatter 的 `name` 要和資料夾名稱一樣（小寫英數字與 `-`），
`description` 會顯示在安裝詢問裡；commit 後同學重跑 install-client 就會被問到。

## HyperFrames 影片（一次問整組）

install-client 問「要安裝 HyperFrames 影片 skill 嗎」選 y（或加 `-Video` / `--video`）時安裝下面四個，
並一併安裝前置軟體。

| skill | 用途 |
|---|---|
| hyperframes | 用 HTML 做影片、動畫、片頭、字幕、圖表的總說明（先讀這個） |
| hyperframes-cli | `npx hyperframes` 指令：建專案、檢查、截圖、預覽、輸出 mp4 |
| hyperframes-registry | 約 450 個現成轉場、字卡、圖表等元件 |
| media-use | 找或做音樂、音效、圖片、配音、字幕稿、去背、調色 |

來源：<https://github.com/heygen-com/hyperframes>（`skills/` 資料夾），2026-10-28 用 `npx skills add heygen-com/hyperframes` 取得。

前置軟體（install-client 會檢查並安裝）：Node.js 22 以上（npx）、FFmpeg、HyperFrames 固定版本的 Chrome（`npx hyperframes browser ensure`）。

## 更新到最新版

```bash
npx skills add heygen-com/hyperframes
```

裝好後把 `~/.agents/skills/` 底下這四個資料夾複製回這裡、commit，同學重跑 install-client 即可更新。
