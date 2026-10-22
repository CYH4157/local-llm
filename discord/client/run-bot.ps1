<#  run-bot.ps1 — 啟動 Discord bot（前景執行，方便看訊息/除錯）#>
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$py  = Join-Path $dir ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { throw "找不到 Python 環境，請先跑 deploy.ps1。" }
Write-Host "啟動 Discord bot… (Ctrl+C 可停止)" -ForegroundColor Cyan
& $py (Join-Path $dir "discord_bot.py")
