<#
    install-autostart.ps1 — 登入時自動啟動：
      1. WSL 常駐（WSL 在沒有任何 Windows 端程序連著時會自動關機，
         裡面的 llama-swap / vLLM 服務也會跟著停，所以要掛一個 sleep 讓它一直活著）
      2. Discord bot（掛掉自動重試）

    需以「系統管理員」執行：
        powershell -ExecutionPolicy Bypass -File .\install-autostart.ps1
#>
param([string]$Distro = "Ubuntu")

$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero)
$trigger = New-ScheduledTaskTrigger -AtLogOn

# --- 1. WSL 常駐 ------------------------------------------------------------
$wslTask = "LocalLLM-WSL-KeepAlive"
$wslAction = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -WindowStyle Hidden -Command `"wsl.exe -d $Distro -e sleep infinity`""
Unregister-ScheduledTask -TaskName $wslTask -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $wslTask -Action $wslAction -Trigger $trigger -Settings $settings `
    -Description "Local LLM - 讓 WSL（vLLM / llama-swap）保持運行" | Out-Null
Start-ScheduledTask -TaskName $wslTask
Write-Host "[OK] 已註冊並啟動『$wslTask』" -ForegroundColor Green

# --- 2. Discord bot ---------------------------------------------------------
$botTask = "LocalLLM-DiscordBot"
$runScript = Join-Path $dir "run-bot.ps1"
$botAction = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runScript`""
Unregister-ScheduledTask -TaskName $botTask -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $botTask -Action $botAction -Trigger $trigger -Settings $settings `
    -Description "Local LLM - Discord bot 自動啟動" | Out-Null
Start-ScheduledTask -TaskName $botTask
Write-Host "[OK] 已註冊並啟動『$botTask』(開機自動啟動、掛掉自動重試)" -ForegroundColor Green

Write-Host ""
Write-Host "筆電提醒：請插電使用，並在『電源設定』把接上電源時的睡眠改為『永不』。" -ForegroundColor Yellow
