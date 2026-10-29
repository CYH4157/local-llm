# opencode skills（HyperFrames 影片）

install-client 問「要安裝 HyperFrames 影片 skill 嗎」選 y（或加 `-Video` / `--video`）時，
這裡每個資料夾會複製到 `~/.config/opencode/skills/<名稱>/`，每個專案都能用。

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
