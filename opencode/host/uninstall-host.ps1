<#
=============================================================================
 uninstall-host.ps1 — 解除安裝 vLLM 主機，並還原 setup-host 改過的 Windows 設定

 最簡單：雙擊 uninstall-host.cmd（會要求系統管理員權限），確認清單後輸入 y。

 會做的事：
   1. 關閉 Tailscale Funnel（有開的話）
   2. 停止並移除排程：vLLM-WSL-KeepAlive、Discord bot（LocalLLM-DiscordBot）
   3. 在 WSL 移除 vLLM 服務、安裝資料夾、金鑰、本專案下載的模型（uninstall-vllm.sh）
   4. 移除防火牆規則（Windows + Hyper-V）
   5. 還原 .wslconfig 的網路模式
   6. 還原電源設定（插電時睡眠 / 休眠 / 闔上螢幕）
   7. 還原 OpenSSH 伺服器（只在 setup-host -EnableSsh 開過時）
   8. 移除這台的 opencode 與設定（client\uninstall-client.ps1）
 有備份（setup-host 第一次安裝時記錄）就還原成原本的值；沒有就改回 Windows 預設值，並列出來。

 參數：
     -KeepModels       保留下載的模型（之後重裝不用再下載約 5~6GB）
     -KeepOpencode     保留這台的 opencode 程式與設定
     -RemoveTailscale  連 Tailscale 一起解除安裝
     -RemoveWsl        連整個 WSL Ubuntu 一起刪除（裡面所有檔案都會消失，無法復原）
     -Port N           vLLM 埠號（預設 8000）
     -Yes              不詢問確認（-RemoveWsl 仍會要求輸入發行版名稱）
=============================================================================
#>
param(
    [switch]$KeepModels,
    [switch]$KeepOpencode,
    [switch]$RemoveTailscale,
    [switch]$RemoveWsl,
    [int]$Port = 8000,
    [string]$Distro = "",
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuleName   = "vLLM-opencode-$Port"
$WslConfig  = Join-Path $env:USERPROFILE ".wslconfig"
$BackupDir  = Join-Path $env:LOCALAPPDATA "vllm-opencode-backup"
$BackupFile = Join-Path $BackupDir "original-settings.json"
$Tasks      = "vLLM-WSL-KeepAlive", "LocalLLM-DiscordBot", "LocalLLM-WSL-KeepAlive"
$Defaulted  = @()   # 沒有備份、改回 Windows 預設值的項目

function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [X]  $m" -ForegroundColor Red; exit 1 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail "請以「系統管理員」執行（或直接雙擊 uninstall-host.cmd）" }

if (-not $Distro) {
    $df = Join-Path $ScriptDir "wsl-distro.txt"
    $Distro = if (Test-Path $df) { (Get-Content $df -Raw).Trim() } else { "Ubuntu" }
}
$distros = @()
try { $distros = @((wsl.exe -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch {}
$HasDistro = $distros -contains $Distro
$Backup = $null
if (Test-Path $BackupFile) { $Backup = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json }

# --- 確認 ---------------------------------------------------------------------
Step "即將解除安裝（WSL 發行版：$Distro）"
Write-Host "  • 關閉 Funnel、移除排程（vLLM 常駐、Discord bot）"
if ($RemoveWsl) { Write-Host "  • 刪除整個 WSL「$Distro」（裡面所有檔案都會消失）" -ForegroundColor Red }
elseif ($HasDistro) { Write-Host "  • WSL 裡的 vLLM 服務、設定與金鑰$(if ($KeepModels) { '（保留模型）' } else { '、下載的模型' })" }
Write-Host "  • 防火牆規則 $RuleName、.wslconfig 網路模式、電源設定、OpenSSH"
if (-not $KeepOpencode) { Write-Host "  • 這台的 opencode 程式與實驗室設定" }
if ($RemoveTailscale) { Write-Host "  • Tailscale" }
if ($Backup) { Ok "找到原本設定的備份（$($Backup.created)），會還原成安裝前的值" }
else { Warn "沒有安裝前的備份（舊版 setup-host 不會備份），電源與網路設定會改回 Windows 預設值" }
Write-Host "  不會動：本 repo 的檔案、Discord bot 的 .env、Scoop、Windows 端的 uv、WSL 功能本身"
if (-not $Yes) {
    $ans = Read-Host "`n確定要繼續嗎？(y/N)"
    if ($ans -notmatch '^[yY]') { Write-Host "已取消"; exit 0 }
}

# --- 1. Funnel ----------------------------------------------------------------
Step "1. Tailscale Funnel"
$ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $ts -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) { $ts = "$env:ProgramFiles\Tailscale\tailscale.exe" }
if ($ts) {
    & $ts funnel --https=443 --set-path=/v1 off 2>$null | Out-Null
    Ok "已關閉 Funnel（若有開啟）"
    if ($RemoveTailscale) {
        winget uninstall --id Tailscale.Tailscale --silent 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok "已解除安裝 Tailscale" } else { Warn "請到「設定 → 應用程式」手動解除安裝 Tailscale" }
    }
} else { Ok "沒有安裝 Tailscale，略過" }

# --- 2. 排程與 Discord bot ----------------------------------------------------
Step "2. 移除排程"
foreach ($t in $Tasks) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Ok "已移除排程 $t"
    }
}
# 排程停止後 bot 的 python 可能還在跑
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*discord_bot.py*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Ok "已停止執行中的 Discord bot（PID $($_.ProcessId)）" }

# --- 3. WSL -------------------------------------------------------------------
Step "3. WSL 裡的 vLLM"
if (-not $HasDistro) {
    Ok "找不到 WSL 的 $Distro，略過"
} elseif ($RemoveWsl) {
    Warn "即將刪除整個「$Distro」：裡面所有檔案（含你自己的資料）都會消失，無法復原！"
    $confirm = Read-Host "請輸入發行版名稱「$Distro」確認刪除（直接按 Enter 取消）"
    if ($confirm -ceq $Distro) {
        wsl.exe --unregister $Distro
        Ok "已刪除 $Distro"
        $HasDistro = $false
    } else {
        Warn "名稱不符，改成只移除 vLLM（不刪 $Distro）"
        $RemoveWsl = $false
    }
}
if ($HasDistro -and -not $RemoveWsl) {
    $src = "$(wsl.exe -d $Distro -e wslpath -a (Join-Path $ScriptDir 'wsl\uninstall-vllm.sh'))".Trim()
    $flag = if ($KeepModels) { "--keep-models" } else { "" }
    # 先轉成 LF 換行再執行；指令裡不能有雙引號（PowerShell 5.1 傳給 wsl.exe 會被吃掉）
    wsl.exe -d $Distro -e bash -c "tr -d '\r' < '$src' > /tmp/uninstall-vllm.sh && bash /tmp/uninstall-vllm.sh $flag"
    if ($LASTEXITCODE -ne 0) { Warn "WSL 端有步驟失敗，請看上方訊息" }
}

# --- 4. 防火牆 ----------------------------------------------------------------
Step "4. 防火牆規則"
if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -Name $RuleName; Ok "已移除 Windows 防火牆規則 $RuleName"
} else { Ok "沒有 Windows 防火牆規則 $RuleName" }
try {
    if (Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $RuleName; Ok "已移除 Hyper-V（WSL）防火牆規則 $RuleName"
    }
} catch {}

# --- 5. .wslconfig ------------------------------------------------------------
Step "5. 還原 WSL 網路模式（$WslConfig）"
if (Test-Path $WslConfig) {
    $lines = @(Get-Content $WslConfig -Encoding UTF8)
    $orig = if ($Backup) { $Backup.wslconfig_net_line } else { $null }
    $new = @()
    foreach ($l in $lines) {
        if ($l -match '^\s*networkingMode\s*=') { if ($orig) { $new += $orig } }   # 換回原本那一行，或刪掉
        else { $new += $l }
    }
    # 只剩空白與 [wsl2] 標題、而且安裝前沒有這個檔 → 整個刪除
    $meaningful = @($new | Where-Object { $_.Trim() -and $_ -notmatch '^\s*\[wsl2\]\s*$' })
    if ($meaningful.Count -eq 0 -and (-not $Backup -or -not $Backup.wslconfig_existed)) {
        Remove-Item $WslConfig -Force
        Ok "已刪除 .wslconfig（安裝前沒有這個檔，或只剩本專案加的設定）"
    } else {
        [IO.File]::WriteAllLines($WslConfig, [string[]]$new, (New-Object Text.UTF8Encoding $false))
        Ok $(if ($orig) { "已還原為原本的設定：$orig" } else { "已移除 networkingMode=mirrored（回到 WSL 預設 NAT 網路）" })
    }
    if (-not $Backup) { $Defaulted += "WSL 網路模式 → NAT（WSL 預設）" }
} else { Ok "沒有 .wslconfig，略過" }
wsl.exe --shutdown 2>$null
Ok "已關閉 WSL（下次開啟時套用新設定）"

# --- 6. 電源 ------------------------------------------------------------------
Step "6. 還原電源設定（插電時）"
function Set-Ac([string]$sub, [string]$setting, $value, [string]$label) {
    if ($null -eq $value) { return }
    powercfg /setacvalueindex SCHEME_CURRENT $sub $setting $value | Out-Null
    Ok "$label → $value"
}
if ($Backup) {
    Set-Ac "SUB_SLEEP"   "STANDBYIDLE"   $Backup.power.standby_ac   "睡眠（秒，0 = 永不）"
    Set-Ac "SUB_SLEEP"   "HIBERNATEIDLE" $Backup.power.hibernate_ac "休眠（秒，0 = 永不）"
    Set-Ac "SUB_BUTTONS" "LIDACTION"     $Backup.power.lid_ac       "闔上螢幕（0 不動作 / 1 睡眠 / 2 休眠 / 3 關機）"
} else {
    # Windows 預設：插電 30 分鐘後睡眠、闔上螢幕 = 睡眠（休眠維持目前設定）
    Set-Ac "SUB_SLEEP"   "STANDBYIDLE" 1800 "睡眠（Windows 預設 30 分鐘）"
    Set-Ac "SUB_BUTTONS" "LIDACTION"   1    "闔上螢幕（Windows 預設：睡眠）"
    $Defaulted += "插電時睡眠 → 30 分鐘、闔上螢幕 → 睡眠（休眠維持目前設定）"
}
powercfg /setactive SCHEME_CURRENT | Out-Null

# --- 7. OpenSSH ---------------------------------------------------------------
Step "7. OpenSSH 伺服器"
if (-not $Backup) {
    Ok "沒有備份，無法判斷是否由本專案開啟，保持不動（需要時到「設定 → 選用功能」移除 OpenSSH 伺服器）"
} else {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $Backup.ssh.capability_installed -and $svc) {
        Stop-Service sshd -Force -ErrorAction SilentlyContinue
        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
        if ($cap -and $cap.State -eq "Installed") { Remove-WindowsCapability -Online -Name $cap.Name | Out-Null }
        Ok "已移除 OpenSSH 伺服器（安裝前沒有）"
    } elseif ($svc) {
        if ($Backup.ssh.start_type) { Set-Service sshd -StartupType $Backup.ssh.start_type }
        if (-not $Backup.ssh.running) { Stop-Service sshd -Force -ErrorAction SilentlyContinue }
        Ok "已還原 sshd：啟動類型 $($Backup.ssh.start_type)、$(if ($Backup.ssh.running) { '執行中' } else { '停止' })"
    } else { Ok "沒有 OpenSSH 伺服器，略過" }
    if (-not $Backup.ssh.firewall_rule_existed -and (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP"; Ok "已移除 SSH 防火牆規則"
    }
}

# --- 8. 這台的 opencode -------------------------------------------------------
Step "8. 這台的 opencode"
if ($KeepOpencode) { Warn "略過（-KeepOpencode）" }
else { & (Join-Path $ScriptDir "..\client\uninstall-client.ps1") -Name laptop }

# --- 收尾 ---------------------------------------------------------------------
Remove-Item (Join-Path $ScriptDir "wsl-distro.txt") -Force -ErrorAction SilentlyContinue
if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force }   # 下次安裝會重新記錄當時的設定

Step "解除安裝完成"
if ($Defaulted.Count -gt 0) {
    Warn "以下項目沒有安裝前的備份，已改回 Windows 預設值，請確認是否符合你的習慣："
    $Defaulted | ForEach-Object { Write-Host "     - $_" }
    Write-Host "     電源：設定 → 系統 → 電源與電池；闔上螢幕：控制台 → 電源選項 → 選擇按下電源按鈕時的行為"
}
Write-Host ""
Write-Host "  仍保留（需要時自行移除）："
if ($HasDistro) { Write-Host "    • WSL「$Distro」本身與 apt 套件、uv（要整個刪除：uninstall-host.cmd -RemoveWsl）" }
Write-Host "    • 本 repo 資料夾（含 Discord bot 的 .env、.venv）：直接刪除資料夾即可"
Write-Host "    • Windows 端的 uv、Scoop：winget uninstall astral-sh.uv ／ scoop uninstall scoop"
if ($ts -and -not $RemoveTailscale) { Write-Host "    • Tailscale：設定 → 應用程式，或 uninstall-host.cmd -RemoveTailscale" }
