<#
=============================================================================
 setup-host.ps1 — 把 Windows 筆電變成主機：WSL2 裡跑 vLLM，Windows 上用 opencode，
                          實驗室其他電腦用筆電的 IP 連進來

 最簡單：雙擊 server\wsl2\setup-host.cmd（會自動要求系統管理員權限）。
 或以「系統管理員」開 PowerShell：
     powershell -ExecutionPolicy Bypass -File .\setup-host.ps1
     powershell -ExecutionPolicy Bypass -File .\setup-host.ps1 -Preset laptop -EnableSsh

 做的事：
     1. 檢查 NVIDIA 驅動、Windows 版本；沒有 WSL 的 Ubuntu 就自動安裝（之後要重開機）
     2. WSL 改用 mirrored 網路：WSL 直接用筆電的 IP，其他電腦連「筆電IP:8000」即可
     3. 註冊開機登入後自動常駐 WSL 的排程（WSL 沒人用時會自動關機，vLLM 也會停）
     4. 在 WSL 的 Ubuntu 裡執行 setup-vllm.sh：安裝 vLLM、模型、金鑰、systemd 服務
     5. 開放防火牆 TCP 8000（Windows 防火牆 + WSL 用的 Hyper-V 防火牆）
     6. 接上電源時不睡眠、闔上螢幕不休眠（-AllowSleep 可略過）
     7. （選用 -EnableSsh）開啟 Windows 的 OpenSSH 伺服器，讓別人 ssh 進來用這台的 opencode
     8. 在這台 Windows 安裝 opencode 並連到本機 vLLM，最後印出給同學的連線資訊

 參數：
     -Preset small|medium|large   模型組合（預設依顯存自動選；8GB 筆電會選 small）
     -Port N                      vLLM 埠號（預設 8000）
     -AllowFrom 來源清單          允許連線的來源，逗號分隔（預設 LocalSubnet＝只允許同網段）
                                  可填 LocalSubnet、Any、IP 或網段，例：LocalSubnet,10.8.0.0/16（加上學校 VPN 網段）
     -EnableSsh                   開啟 OpenSSH 伺服器
     -AllowSleep                  不要更改電源設定
     -SkipOpencode                這台不安裝 opencode
     -SkipVllm                    vLLM 已裝好時跳過 WSL 安裝，只做 Windows 端設定（防火牆、電源、opencode）
     -Distro NAME                 WSL 發行版名稱（預設 Ubuntu）

 可重複執行：已完成的步驟會略過或更新。
=============================================================================
#>
param(
    [ValidateSet("auto", "small", "medium", "large")]
    [string]$Preset = "auto",
    [int]$Port = 8000,
    [string]$AllowFrom = "LocalSubnet",
    [switch]$EnableSsh,
    [switch]$AllowSleep,
    [switch]$SkipOpencode,
    [switch]$SkipVllm,
    [string]$Distro = "Ubuntu"
)
$ErrorActionPreference = "Stop"
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RuleName     = "vLLM-opencode-$Port"
$TaskName     = "vLLM-WSL-KeepAlive"
$WslCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"   # WSL 的 Hyper-V 防火牆 VM Creator ID（微軟文件固定值）
$WslConfig    = Join-Path $env:USERPROFILE ".wslconfig"

function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [X]  $m" -ForegroundColor Red; exit 1 }

# 來源清單：LocalSubnet / Any / IP / 網段（CIDR），逗號或分號分隔
$AllowList = @($AllowFrom -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($a in $AllowList) {
    if ($a -notmatch '^(LocalSubnet|Any|\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?)$') {
        Fail "-AllowFrom 的「$a」格式不對：只能填 LocalSubnet、Any、IP 或網段（例 10.8.0.0/16），用逗號分隔"
    }
}
if (-not $AllowList) { $AllowList = @("LocalSubnet") }
if ($AllowList -contains "Any") {
    $AllowList = @("Any")
    # 筆電是公開 IP（台灣學校常見 140.x）時，Any = 全世界都連得到 8000 port（而且是沒加密的 HTTP）
    $myIp = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
             Select-Object -First 1).IPv4Address.IPAddress
    if ($myIp -and $myIp -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') {
        Warn "這台的 IP（$myIp）是公開 IP：-AllowFrom Any 會讓整個網際網路都連得到 vLLM！"
        Warn "建議改成只開放學校網段，例：-AllowFrom LocalSubnet,<學校VPN網段>"
    }
}
$AllowText = $AllowList -join ", "

function Invoke-Wsl([string]$cmd) { wsl.exe -d $Distro -e bash -c $cmd }
function Get-WslValue([string]$name) {
    # 讀 WSL 裡 ~/vllm-server/vllm.env 的值（值不含空白）
    $v = wsl.exe -d $Distro -e bash -c ". ~/vllm-server/vllm.env 2>/dev/null; printf %s `$$name"
    return "$v".Trim()
}

# --- 0. 前置檢查 --------------------------------------------------------------
Step "0. 前置檢查"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Fail "請以「系統管理員」執行（或直接雙擊 setup-host.cmd）" }
if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    Fail "找不到 nvidia-smi：請先到 NVIDIA 官網安裝最新版顯示卡驅動"
}
Ok "GPU：$((nvidia-smi --query-gpu=name,memory.total --format=csv,noheader) 2>$null)"
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$Mirrored = $build -ge 22621
if ($Mirrored) { Ok "Windows build $build（支援 WSL mirrored 網路）" }
else { Warn "Windows build $build：mirrored 網路需要 Windows 11 22H2 以上，其他電腦將無法連到這台的 vLLM（本機仍可使用）" }

# --- 1. WSL + Ubuntu ----------------------------------------------------------
Step "1. 檢查 WSL2 / Ubuntu"
# 解析 wsl -l -v（輸出是 UTF-16，要去掉 \0）：每行「* 名稱  狀態  版本」
$installed = @()
try {
    foreach ($line in ((wsl.exe -l -v) -replace "`0", "")) {
        if ($line -match '^\s*\*?\s*(\S+)\s+\S+\s+([12])\s*$') {
            $installed += [pscustomobject]@{ Name = $Matches[1]; Version = [int]$Matches[2] }
        }
    }
} catch {}
# 沒有用 -Distro 指定時，自動找已安裝的 Ubuntu（例如 Ubuntu-24.04），避免重複安裝
if (-not $PSBoundParameters.ContainsKey('Distro') -and -not ($installed | Where-Object Name -eq $Distro)) {
    $found = $installed | Where-Object { $_.Name -like 'Ubuntu*' } | Select-Object -First 1
    if ($found) {
        $Distro = $found.Name
        Warn "找到已安裝的 $Distro，改用它（要指定別的請加 -Distro 名稱）"
    }
}
$entry = $installed | Where-Object Name -eq $Distro | Select-Object -First 1
if (-not $entry) {
    Warn "尚未安裝 WSL 的 $Distro，開始安裝…"
    wsl.exe --install -d $Distro
    Write-Host ""
    Warn "安裝完成後請："
    Write-Host "     1) 重新開機"
    Write-Host "     2) 從開始選單開啟「$Distro」，設定 Ubuntu 的使用者名稱與密碼（密碼要記住）"
    Write-Host "     3) 再雙擊一次 setup-host.cmd"
    exit 0
}
# WSL1 不能使用 GPU，轉成 WSL2（約需數分鐘，資料會保留）
if ($entry.Version -ne 2) {
    Warn "$Distro 是 WSL1（無法使用 GPU），轉換成 WSL2，約需數分鐘…"
    wsl.exe --set-version $Distro 2
    if ($LASTEXITCODE -ne 0) {
        Fail "轉換失敗：請確認 BIOS 已開啟虛擬化（Intel VT-x / AMD-V），並執行 wsl --update 後再試"
    }
    Ok "已轉換成 WSL2"
}
$uid = "$(wsl.exe -d $Distro -e id -u)".Trim()
if ($uid -eq "0") { Fail "$Distro 的預設使用者是 root：請先從開始選單開啟 $Distro 建立一般使用者" }
# 記下發行版名稱，vllmctl.cmd 會讀這個檔
[IO.File]::WriteAllText((Join-Path $ScriptDir "wsl-distro.txt"), $Distro, [Text.Encoding]::ASCII)
Ok "$Distro（WSL2）已就緒"

# --- 備份原本的設定（只在第一次安裝時記錄；uninstall-host 用來還原）-----------
$BackupDir  = Join-Path $env:LOCALAPPDATA "vllm-opencode-backup"
$BackupFile = Join-Path $BackupDir "original-settings.json"
function Get-AcValue([string]$sub, [string]$setting) {
    # /qh 連隱藏設定（例如闔上螢幕）也會列出；含「AC」的那一行就是插電時的值
    $line = powercfg /qh SCHEME_CURRENT $sub $setting 2>$null | Select-String ' AC .*0x' | Select-Object -First 1
    if ($line) { return [Convert]::ToInt32(($line -replace '^.*0x', ''), 16) } else { return $null }
}
if (-not (Test-Path $BackupFile)) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $netLine = $null
    if (Test-Path $WslConfig) {
        $netLine = Get-Content $WslConfig -Encoding UTF8 | Where-Object { $_ -match '^\s*networkingMode\s*=' } | Select-Object -First 1
    }
    $sshCap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $sshSvc = Get-Service sshd -ErrorAction SilentlyContinue
    $backup = [ordered]@{
        created            = (Get-Date).ToString("s")
        wslconfig_existed  = [bool](Test-Path $WslConfig)
        wslconfig_net_line = $netLine
        power = [ordered]@{
            standby_ac   = Get-AcValue "SUB_SLEEP" "STANDBYIDLE"
            hibernate_ac = Get-AcValue "SUB_SLEEP" "HIBERNATEIDLE"
            lid_ac       = Get-AcValue "SUB_BUTTONS" "LIDACTION"
        }
        ssh = [ordered]@{
            capability_installed = [bool]($sshCap -and $sshCap.State -eq "Installed")
            start_type           = if ($sshSvc) { "$($sshSvc.StartType)" } else { $null }
            running              = [bool]($sshSvc -and $sshSvc.Status -eq "Running")
            firewall_rule_existed = [bool](Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)
        }
    }
    [IO.File]::WriteAllText($BackupFile, ($backup | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Ok "已備份原本的設定（解除安裝時還原）：$BackupFile"
}

# --- 2. mirrored 網路 ---------------------------------------------------------
Step "2. WSL 網路設定（$WslConfig）"
if ($Mirrored) {
    $lines = @()
    if (Test-Path $WslConfig) { $lines = @(Get-Content $WslConfig -Encoding UTF8) }
    if (-not ($lines | Where-Object { $_ -match '^\s*networkingMode\s*=\s*mirrored' })) {
        $lines = @($lines | Where-Object { $_ -notmatch '^\s*networkingMode\s*=' })
        $idx = [Array]::FindIndex([string[]]$lines, [Predicate[string]]{ param($l) $l -match '^\s*\[wsl2\]\s*$' })
        if ($idx -ge 0) {
            $after = if ($idx + 1 -lt $lines.Count) { $lines[($idx + 1)..($lines.Count - 1)] } else { @() }
            $lines = @($lines[0..$idx]) + "networkingMode=mirrored" + @($after)
        } else {
            $lines += @("", "[wsl2]", "networkingMode=mirrored")
        }
        [IO.File]::WriteAllLines($WslConfig, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
        Ok "已設定 networkingMode=mirrored，重啟 WSL 套用"
        wsl.exe --shutdown
        Start-Sleep 5
    } else {
        Ok "已是 mirrored 模式"
    }
} else {
    Warn "略過（Windows 版本不支援）"
}

# --- 3. 讓 WSL 常駐 -----------------------------------------------------------
Step "3. 註冊排程「$TaskName」（登入後自動啟動並常駐 WSL）"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew
# 不顯示任何視窗（直接跑 wsl.exe 會跳出黑色視窗，被順手關掉 WSL 就停了）
# Windows 11 用 conhost --headless 完全隱藏；舊版退回 PowerShell 隱藏視窗
if ($Mirrored) {
    $action = New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless wsl.exe -d $Distro -e sleep infinity"
} else {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-NoProfile -WindowStyle Hidden -Command `"wsl.exe -d $Distro -e sleep infinity`""
}
# 登入時啟動，之後每 5 分鐘檢查一次：WSL 若被關掉就自動重新啟動（已在執行則略過）
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "vLLM + opencode：讓 WSL 裡的 vLLM 服務保持運行" | Out-Null
Start-ScheduledTask -TaskName $TaskName
Ok "已註冊並啟動（不顯示視窗；每 5 分鐘自動檢查；重開機後要登入 Windows，vLLM 才會啟動）"

# --- 4. 在 WSL 安裝 vLLM ------------------------------------------------------
Step "4. 在 $Distro 安裝 vLLM（會詢問 Ubuntu 密碼；第一次約 20~40 分鐘）"
$src = "$(wsl.exe -d $Distro -e wslpath -a ([IO.Path]::GetFullPath((Join-Path $ScriptDir "..\vllm"))))".Trim()
Invoke-Wsl "mkdir -p ~/vllm-opencode-setup && cp '$src'/*.sh '$src'/*.py ~/vllm-opencode-setup/ && sed -i 's/\r$//' ~/vllm-opencode-setup/*.sh ~/vllm-opencode-setup/*.py"
if ($SkipVllm) {
    Warn "略過（-SkipVllm），沿用 WSL 裡已安裝的 vLLM"
} else {
$vllmArgs = "--port $Port"
if ($Preset -ne "auto") { $vllmArgs += " --preset $Preset" }
$cmd = "bash ~/vllm-opencode-setup/setup-vllm.sh $vllmArgs"
Invoke-Wsl $cmd
if ($LASTEXITCODE -eq 2) {
    Warn "剛開啟 WSL 的 systemd，重啟 WSL 後繼續…"
    wsl.exe --shutdown
    Start-Sleep 5
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep 3
    Invoke-Wsl $cmd
}
if ($LASTEXITCODE -ne 0) { Fail "WSL 端安裝失敗（exit $LASTEXITCODE），請看上方訊息" }
}
$Key   = Get-WslValue "SERVE_API_KEY"
$Model = Get-WslValue "SERVE_NAME"
if (-not $Key) { Fail "讀不到 API 金鑰（~/vllm-server/vllm.env）" }
Ok "vLLM 安裝完成，模型：$Model"

# --- 5. 防火牆 ----------------------------------------------------------------
Step "5. 開放防火牆 TCP $Port（來源：$AllowText）"
Remove-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue
New-NetFirewallRule -Name $RuleName -DisplayName "vLLM for opencode TCP $Port" `
    -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow `
    -RemoteAddress $AllowList -Profile Any | Out-Null
Ok "Windows 防火牆規則：$RuleName（來源：$AllowText）"
if ($Mirrored) {
    try {
        try { Remove-NetFirewallHyperVRule -Name $RuleName -ErrorAction Stop } catch {}
        $hv = @{ Name = $RuleName; DisplayName = "vLLM for opencode TCP $Port"; Direction = "Inbound"
                 VMCreatorId = $WslCreatorId; Protocol = "TCP"; LocalPorts = $Port; Action = "Allow" }
        if ($AllowList -notcontains "Any") { $hv.RemoteAddresses = [string[]]$AllowList }
        try { New-NetFirewallHyperVRule @hv | Out-Null }
        catch {
            # 部分 Windows 版本的 Hyper-V 防火牆不支援 LocalSubnet，改為不限制來源（仍需 API 金鑰）
            $hv.Remove("RemoteAddresses"); New-NetFirewallHyperVRule @hv | Out-Null
            Warn "Hyper-V 防火牆不支援限制來源網段，改為不限制（仍需 API 金鑰才能使用）"
        }
        Ok "Hyper-V 防火牆（WSL）規則：$RuleName"
    } catch {
        if (Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue) { Ok "Hyper-V 防火牆（WSL）規則已存在：$RuleName" }
        else { Warn "無法建立 Hyper-V 防火牆規則：$($_.Exception.Message)" }
    }
}

# --- 6. 電源 ------------------------------------------------------------------
Step "6. 電源設定"
if ($AllowSleep) {
    Warn "略過（-AllowSleep）"
} else {
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Ok "接上電源時：不睡眠、不休眠、闔上螢幕不動作（用電池時維持原設定）"
}

# --- 7. SSH（選用）-------------------------------------------------------------
Step "7. OpenSSH 伺服器"
if ($EnableSsh) {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
    if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
    }
    Ok "sshd 已啟動（用 Windows 帳號密碼登入）"
} else {
    Warn "略過（需要讓別人 ssh 進來用這台的 opencode 時加 -EnableSsh）"
}

# --- 8. 測試 + 本機 opencode --------------------------------------------------
Step "8. 測試連線"
$ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
       Select-Object -First 1).IPv4Address.IPAddress
$okLocal = $false
foreach ($i in 1..60) {
    try {
        Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -TimeoutSec 3 -Headers @{ Authorization = "Bearer $Key" } | Out-Null
        $okLocal = $true; break
    } catch { Start-Sleep 5 }
}
if ($okLocal) { Ok "本機：http://127.0.0.1:$Port/v1" }
else { Fail "本機連不到 vLLM，查看紀錄：雙擊 vllmctl.cmd 輸入 logs，或 wsl -d $Distro -e journalctl -u vllm -n 50" }
if ($Mirrored -and $ip) {
    try {
        Invoke-RestMethod "http://${ip}:$Port/v1/models" -TimeoutSec 5 -Headers @{ Authorization = "Bearer $Key" } | Out-Null
        Ok "區網：http://${ip}:$Port/v1"
    } catch { Warn "用區網 IP 連線失敗（$($_.Exception.Message)），請用另一台電腦再測試" }
}

if (-not $SkipOpencode) {
    Step "9. 在這台 Windows 安裝 opencode"
    & (Join-Path $ScriptDir "..\..\opencode\client\install-client.ps1") -Url "http://127.0.0.1:$Port/v1" -Key $Key -Name laptop -Default
}

Step "完成！把以下資訊給實驗室同學"
Write-Host ""
Write-Host "  vLLM 網址：http://${ip}:$Port/v1" -ForegroundColor Cyan
Write-Host "  API 金鑰 ：$Key" -ForegroundColor Cyan
Write-Host "  模型名稱 ：$Model" -ForegroundColor Cyan
Write-Host ""
Write-Host "  同學的 Windows 電腦：複製 opencode 資料夾 → 雙擊 opencode\client\install-client.cmd → 貼上網址與金鑰"
Write-Host "  同學的 Ubuntu 電腦 ：bash opencode/client/install-client.sh --url http://${ip}:$Port/v1 --key $Key --name laptop"
if ($EnableSsh) { Write-Host "  SSH 進這台：ssh $env:USERNAME@$ip（登入後輸入 opencode）" }
Write-Host ""
Write-Host "  這台自己用：開「終端機」，cd 到專案資料夾，輸入 opencode"
Write-Host "  管理 vLLM ：雙擊 vllmctl.cmd（status / logs / restart / preset / new-key）"
Write-Host ""
Warn "筆電請接電源；IP 可能因 DHCP 改變，建議請網管或在路由器幫筆電固定 IP。"
Warn "金鑰請只私下給實驗室成員；外流時用 vllmctl.cmd new-key 換新。"
