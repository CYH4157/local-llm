<#  install-autostart.ps1 — 讓 Discord bot 開機/登入時自動啟動、掛掉自動重試 #>
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runScript = Join-Path $dir "run-bot.ps1"
$taskName  = "LocalLLM-DiscordBot"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Local LLM - Discord bot 自動啟動" | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "[OK] 已註冊並啟動『$taskName』(開機自動啟動、掛掉自動重試)" -ForegroundColor Green
