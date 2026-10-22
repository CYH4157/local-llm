<#
    install-autostart.ps1 — 讓 Discord bot 登入時自動啟動、掛掉自動重試

    WSL / vLLM 的常駐由 opencode 專案的排程「vLLM-WSL-KeepAlive」負責，這裡不重複設定。

    需以「系統管理員」執行：
        powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1
#>
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 舊版自己註冊的 WSL 常駐排程，改由 opencode 專案負責 → 移除
if (Get-ScheduledTask -TaskName "LocalLLM-WSL-KeepAlive" -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName "LocalLLM-WSL-KeepAlive" -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "LocalLLM-WSL-KeepAlive" -Confirm:$false
    Write-Host "[OK] 已移除舊排程 LocalLLM-WSL-KeepAlive（改由 opencode 的 vLLM-WSL-KeepAlive 負責）" -ForegroundColor Green
}
if (-not (Get-ScheduledTask -TaskName "vLLM-WSL-KeepAlive" -ErrorAction SilentlyContinue)) {
    Write-Host "[!] 找不到 opencode 專案的 vLLM-WSL-KeepAlive 排程，重開機後 vLLM 可能不會自動啟動" -ForegroundColor Yellow
}

$taskName  = "LocalLLM-DiscordBot"
$runScript = Join-Path $dir "run-bot.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Local LLM - Discord bot 自動啟動" | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "[OK] 已註冊並啟動『$taskName』(開機自動啟動、掛掉自動重試)" -ForegroundColor Green
