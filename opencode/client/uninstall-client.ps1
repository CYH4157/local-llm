<#
=============================================================================
 uninstall-client.ps1 — 移除 install-client 裝的東西（Windows）

 最簡單：雙擊 uninstall-client.cmd。
     會移除：opencode 設定裡的實驗室 provider（預設 laptop）、實驗室共用規則 AGENTS.md、
             文件工具 labdoc 與實驗室的 /指令、opencode 程式
     不會動：你自己加的其他 provider / 設定、Scoop 本身（可能裝了其他軟體）

 參數：
     -Name laptop     要移除的 provider 名稱，逗號分隔（安裝時的 -Name）；
                      不填 = servers.json 裡的每一台（沒有 servers.json 時是 laptop）
     -KeepProgram     只移除設定，保留 opencode 程式（例如還要用它連別的模型）
=============================================================================
#>
param(
    [string]$Name,
    [switch]$KeepProgram
)
$ErrorActionPreference = "Stop"
function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }

$cfgDir  = Join-Path $env:USERPROFILE ".config\opencode"
$cfgPath = Join-Path $cfgDir "opencode.json"

$names = @("laptop")
$listPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\servers.json"))   # opencode\servers.json
if ($Name) {
    $names = @($Name -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} elseif (Test-Path $listPath) {
    try { $names = @((Get-Content $listPath -Raw -Encoding UTF8 | ConvertFrom-Json).servers | Where-Object { $_.name } | ForEach-Object { "$($_.name)" }) }
    catch { Warn "servers.json 無法解析，只移除 laptop" }
}

# --- 1. opencode 設定 ---------------------------------------------------------
Step "1. 移除 opencode 設定裡的 provider「$($names -join ', ')」"
$providersLeft = @()   # 移除後還剩下的 provider（有剩就保留共用規則）
if (-not (Test-Path $cfgPath)) {
    Ok "沒有設定檔，略過"
} else {
    Copy-Item $cfgPath "$cfgPath.uninstall-bak" -Force
    $cfg = $null
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Warn "設定檔無法解析，保留不動：$cfgPath" }
    if ($cfg) {
        foreach ($n in $names) {
            if ($cfg.PSObject.Properties['provider'] -and $cfg.provider.PSObject.Properties[$n]) {
                $cfg.provider.PSObject.Properties.Remove($n)
                Ok "已移除 provider $n"
            } else {
                Ok "設定裡沒有 provider $n"
            }
            # 預設模型指向被移除的 provider → 一併移除，opencode 會改用其他可用的模型
            foreach ($p in 'model', 'small_model') {
                if ($cfg.PSObject.Properties[$p] -and "$($cfg.$p)" -like "$n/*") { $cfg.PSObject.Properties.Remove($p) }
            }
        }
        # 用 ForEach-Object 取名稱：provider 已經空了時 .Properties.Name 會是 $null，@($null) 會被當成還剩 1 台
        if ($cfg.PSObject.Properties['provider']) { $providersLeft = @($cfg.provider.PSObject.Properties | ForEach-Object { $_.Name }) }
        $left = @($cfg.PSObject.Properties | Where-Object { $_.Name -ne '$schema' -and
                  -not ($_.Name -eq 'provider' -and @($_.Value.PSObject.Properties).Count -eq 0) })
        if ($left.Count -eq 0) {
            Remove-Item $cfgPath -Force
            Ok "設定檔已沒有其他內容，整個刪除（備份：opencode.json.uninstall-bak）"
        } else {
            [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
            Ok "已更新設定檔，其他設定保留（備份：opencode.json.uninstall-bak）"
        }
    }
}
Remove-Item "$cfgPath.bak" -Force -ErrorAction SilentlyContinue   # install-client 留下的舊備份（含金鑰）

# --- 2. 實驗室共用規則 --------------------------------------------------------
Step "2. 移除實驗室共用規則（AGENTS.md）"
$rules = Join-Path $cfgDir "AGENTS.md"
if ($providersLeft.Count -gt 0) {
    Ok "還有其他伺服器（$($providersLeft -join ', ')），保留共用規則"
} elseif ((Test-Path $rules) -and (Select-String -Path $rules -Pattern "lab-opencode-rules" -Quiet)) {
    Remove-Item $rules -Force
    Ok "已刪除 $rules"
} elseif (Test-Path $rules) {
    Ok "AGENTS.md 是你自己的版本，保留"
} else {
    Ok "沒有安裝，略過"
}

# --- 2b. 文件工具 labdoc 與 /指令（跟共用規則一樣：還有其他伺服器就保留） --------
Step "2b. 移除文件工具 labdoc 與 /指令"
$toolDir = Join-Path $cfgDir "labdoc"
$binDir  = Join-Path $toolDir "bin"
$cmdDir  = Join-Path $cfgDir "command"
if ($providersLeft.Count -gt 0) {
    Ok "還有其他伺服器（$($providersLeft -join ', ')），保留文件工具與 /指令"
} else {
    if (Test-Path $toolDir) {
        Get-Process labdoc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item $toolDir -Recurse -Force
        Ok "已刪除 $toolDir"
    } else {
        Ok "沒有安裝 labdoc，略過"
    }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (@("$userPath" -split ';') -contains $binDir) {
        [Environment]::SetEnvironmentVariable("Path", (@("$userPath" -split ';') | Where-Object { $_ -and $_ -ne $binDir }) -join ';', "User")
        Ok "已從使用者 PATH 移除 $binDir"
    }
    # 只刪實驗室裝的指令（有 lab-opencode-command 標記），自己寫的保留
    $removedCmds = @(Get-ChildItem $cmdDir -Filter *.md -ErrorAction SilentlyContinue |
        Where-Object { Select-String -Path $_.FullName -Pattern "lab-opencode-command" -Quiet })
    $removedCmds | Remove-Item -Force
    if ($removedCmds) { Ok "已刪除指令：$(($removedCmds | ForEach-Object { "/$($_.BaseName)" }) -join ' ')" }
    if ((Test-Path $cmdDir) -and -not (Get-ChildItem $cmdDir -Force)) { Remove-Item $cmdDir -Force }
}
if ((Test-Path $cfgDir) -and -not (Get-ChildItem $cfgDir -Force | Where-Object { $_.Name -notlike "*.uninstall-bak" })) {
    Ok "設定資料夾只剩備份檔：$cfgDir（確認不需要後可自行刪除）"
}

# --- 3. opencode 程式 ---------------------------------------------------------
Step "3. 移除 opencode 程式"
if ($KeepProgram) {
    Warn "略過（-KeepProgram）"
} else {
    $removed = $false
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        # 新版 scoop list 回傳物件（.Name），舊版回傳文字（第一欄是名稱）
        function Get-ScoopApps { @(scoop list 6>$null 2>$null | ForEach-Object { if ($_.Name) { "$($_.Name)" } else { ("$_".Trim() -split '\s+')[0] } } | Where-Object { $_ }) }
        if ((Get-ScoopApps) -contains "opencode") {
            scoop uninstall opencode
            $removed = $true
            Ok "已用 Scoop 移除 opencode"
            if (@(Get-ScoopApps).Count -eq 0) { Warn "Scoop 已沒有其他軟體；要連 Scoop 一起移除可執行：scoop uninstall scoop" }
        }
    }
    if (-not $removed -and (Get-Command npm -ErrorAction SilentlyContinue)) {
        foreach ($pkg in "@opencode/cli", "opencode-ai") {
            if (npm ls -g --depth=0 $pkg 2>$null | Select-String $pkg -Quiet) {
                npm uninstall -g $pkg | Out-Null
                $removed = $true
                Ok "已用 npm 移除 $pkg"
            }
        }
    }
    if (-not $removed) {
        if (Get-Command opencode -ErrorAction SilentlyContinue) {
            Warn "終端機版 opencode 不是用 Scoop / npm 安裝的（$((Get-Command opencode).Source)），請自行移除"
        } else {
            Ok "沒有安裝終端機版"
        }
    }
    # 桌面版：用安裝程式登記的靜默解除安裝指令（只裝給目前使用者，不需系統管理員）
    $entry = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match '^OpenCode\b' -and $_.QuietUninstallString } | Select-Object -First 1
    if ($entry) {
        Get-Process OpenCode -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($entry.QuietUninstallString -match '^"([^"]+)"\s*(.*)$') {
            Start-Process $Matches[1] -ArgumentList $Matches[2] -Wait
        }
        if (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\@opencodedesktop\OpenCode.exe")) {
            Warn "桌面版沒有移除乾淨，請到「設定 → 應用程式」解除安裝 OpenCode"
        } else {
            Ok "已移除桌面版（$($entry.DisplayName)）"
        }
        $data = Join-Path $env:APPDATA "ai.opencode.desktop"
        if (Test-Path $data) { Warn "桌面版的對話紀錄與設定保留在 $data（不需要可自行刪除）" }
    } else {
        Ok "沒有安裝桌面版"
    }
}

Step "完成"
