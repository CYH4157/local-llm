<#
=============================================================================
 install-client.ps1 — Windows 電腦安裝 opencode，並連到實驗室筆電（WSL）上的 vLLM

 最簡單：雙擊 install-client.cmd，依提示貼上筆電的網址與金鑰。
 管理者也可以先把網址、金鑰填進 opencode\servers.json（照 servers.example.json 複製），
 同學雙擊後就會自動加入裡面的每一台，不用自己輸入（servers.json 有金鑰，不會上傳到 git）。
 或在 PowerShell 執行（網址與金鑰在筆電上執行 bash vllmctl.sh info 可看到）：
     powershell -ExecutionPolicy Bypass -File install-client.ps1 -Url http://192.168.1.23:8000/v1 -Key sk-vllm-xxx

 參數：
     -Url          筆電的 vLLM 網址（要含 /v1）
     -Key          筆電的 API 金鑰
     -Name         provider 名稱（預設 laptop，opencode 裡顯示用）
     -Default      設成 opencode 的預設模型（第一次安裝會自動設定）
     -SkipInstall  不安裝 opencode，只寫設定（已經裝好或使用桌面版時）
     -Models       只加入這些模型，逗號分隔（伺服器模型很多時用，例如國網 API）
     -Context      伺服器沒回報上下文長度時使用的值（預設 16384）
     -Label        opencode 裡顯示的 provider 名稱（預設「vLLM (Name)」）

 也可以連其他 OpenAI 相容的 API，例如國網：雙擊 install-nchc.cmd

 可重複執行：會合併進 %USERPROFILE%\.config\opencode\opencode.json，不會刪掉其他設定。
=============================================================================
#>
param(
    [string]$Url,
    [string]$Key,
    [string]$Name = "laptop",
    [switch]$Default,
    [switch]$SkipInstall,
    [string]$Models,
    [int]$Context = 16384,
    [string]$Label,
    [switch]$FromList     # 內部用：由 servers.json 逐台呼叫時，不印最後的使用說明
)
$ErrorActionPreference = "Stop"
function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Show-Usage {
    Step "完成"
    Write-Host "  1. 開啟「終端機」（Windows Terminal）或 PowerShell（剛裝好 opencode 的話要開新的視窗）"
    Write-Host "  2. cd 到你的專案資料夾，例如：cd $env:USERPROFILE\Documents\my-thesis"
    Write-Host "  3. 輸入：opencode"
    Write-Host "  在 opencode 裡輸入 /models 可以切換伺服器與模型。"
}

# --- 0. servers.json：管理者預先填好的伺服器清單 -----------------------------
$listPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\servers.json"))   # opencode\servers.json
if (-not $Url -and -not $FromList -and (Test-Path $listPath)) {
    try { $list = Get-Content $listPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host "  servers.json 格式不對（常見：少了逗號或引號）：$($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    $servers = @($list.servers | Where-Object { $_ -and $_.enabled -ne $false })
    if (-not $servers) { Write-Host "  servers.json 裡沒有任何伺服器" -ForegroundColor Red; exit 1 }
    Write-Host "讀取 $listPath：共 $($servers.Count) 台伺服器"
    $done = @(); $failed = @()
    foreach ($s in $servers) {
        if (-not $s.url -or -not $s.name) { Warn "有一筆缺少 name 或 url，略過"; continue }
        $a = @{ Url = "$($s.url)"; Name = "$($s.name)"; FromList = $true }
        # 金鑰是空的（例如每個人自己的國網金鑰）→ 執行時再問
        if ($s.key -and "$($s.key)" -notmatch '^請填') { $a.Key = "$($s.key)" }
        if ($s.label)   { $a.Label = "$($s.label)" }
        if ($s.context) { $a.Context = [int]$s.context }
        if ($s.models)  { $a.Models = (@($s.models) -join ',') }
        if ($s.default) { $a.Default = $true }
        if ($SkipInstall) { $a.SkipInstall = $true }
        Write-Host "`n######## $(if ($s.label) { $s.label } else { $s.name }) ########" -ForegroundColor Magenta
        try { & $PSCommandPath @a; $ok = ($LASTEXITCODE -eq 0) } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red; $ok = $false }
        if ($ok) { $done += "$($s.name)" } else { $failed += "$($s.name)" }
    }
    if ($done)   { Ok "已加入：$($done -join ', ')" }
    if ($failed) { Warn "沒加入：$($failed -join ', ')（看上面的錯誤訊息；修好後再雙擊一次即可）" }
    if ($done) { Show-Usage }
    exit $(if ($failed) { 1 } else { 0 })
}

if (-not $Url) { $Url = Read-Host "筆電的 vLLM 網址（例：http://192.168.1.23:8000/v1）" }
# 在筆電本機安裝（網址是 127.0.0.1 / localhost）且沒給金鑰：直接從 WSL 的 vllm.env 讀，指令裡不必出現金鑰
if (-not $Key -and $Url -match '://(127\.0\.0\.1|localhost)[:/]') {
    $distro = "Ubuntu"
    foreach ($df in (Join-Path $PSScriptRoot "wsl-distro.txt"), (Join-Path $PSScriptRoot "..\..\server\wsl2\wsl-distro.txt")) {
        if (Test-Path $df) { $distro = (Get-Content $df -Raw).Trim(); break }
    }
    $Key = "$(wsl.exe -d $distro -e bash -c '. ~/vllm-server/vllm.env 2>/dev/null; printf %s $SERVE_API_KEY')".Trim()
    if ($Key) { Write-Host "  已從 WSL（$distro）讀取 API 金鑰" }
}
if (-not $Key) { $Key = Read-Host "$(if ($Label) { "$Label 的 " })API 金鑰（sk-...）" }
$Url = $Url.Trim().TrimEnd('/')
$Key = $Key.Trim()
if ($Url -notmatch '^https?://') { $Url = "http://$Url" }
if ($Url -notmatch '/v1$') { $Url = "$Url/v1" }
if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw "-Name 只能用英數字、- 和 _" }

# --- 1. 測試連線 --------------------------------------------------------------
Step "1. 測試連線 $Url"
try {
    $served = Invoke-RestMethod -Uri "$Url/models" -Headers @{ Authorization = "Bearer $Key" } -TimeoutSec 10
} catch {
    Write-Host "  連不到 $Url/models ：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  請確認：伺服器有開機、IP 正確、金鑰正確；伺服器要走 VPN 的話，先連上 VPN。" -ForegroundColor Red
    exit 1
}
if (-not $served.data) { Write-Host "  伺服器沒有回傳任何模型" -ForegroundColor Red; exit 1 }
if ($Models) {
    $want = @($Models -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $missing = @($want | Where-Object { $_ -notin $served.data.id })
    if ($missing) { Warn "伺服器上沒有這些模型，略過：$($missing -join ', ')" }
    # 依 -Models 的順序排，第一個就是預設模型
    $served.data = @(foreach ($w in $want) { $served.data | Where-Object { $_.id -eq $w } })
    if (-not $served.data) { Write-Host "  -Models 指定的模型伺服器上都沒有" -ForegroundColor Red; exit 1 }
}
foreach ($m in $served.data) { Write-Host "  - $($m.id)  (context $(if ($m.max_model_len) { $m.max_model_len } else { "未回報，用 $Context" }))" }
Ok "連線成功"

# --- 2. 安裝 opencode ---------------------------------------------------------
Step "2. 安裝 opencode"
function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "Machine")
}
if ($SkipInstall) {
    Warn "略過（-SkipInstall）"
} elseif (Get-Command opencode -ErrorAction SilentlyContinue) {
    Ok "已安裝：$((Get-Command opencode).Source)"
} else {
    if (Get-Command scoop -ErrorAction SilentlyContinue) {
        scoop install opencode
    } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
        npm i -g "@opencode/cli@latest"
    } else {
        # Scoop：Windows 套件管理員，裝在使用者目錄，不需要系統管理員權限
        Warn "安裝 Scoop（用來安裝 opencode，裝在 $env:USERPROFILE\scoop）"
        # Scoop 需要 CurrentUser 至少 RemoteSigned；已經設好就跳過。
        # 用 -ExecutionPolicy Bypass 執行時，PowerShell 會把「已更新但被 Process 範圍覆蓋」當成錯誤丟出，這裡吞掉
        if ((Get-ExecutionPolicy -Scope CurrentUser) -in @("Undefined", "Restricted", "AllSigned")) {
            try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop } catch {}
        }
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            # 從 server\wsl2\setup-host.ps1（系統管理員）呼叫時，Scoop 需要 -RunAsAdmin 才肯安裝
            Invoke-Expression "& {$(Invoke-RestMethod -Uri 'https://get.scoop.sh')} -RunAsAdmin"
        } else {
            Invoke-RestMethod -Uri "https://get.scoop.sh" | Invoke-Expression
        }
        Update-SessionPath
        scoop install opencode
    }
    Update-SessionPath
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        Write-Host "  opencode 安裝失敗。可改到 https://opencode.ai/download 下載桌面版，再用 -SkipInstall 重跑本腳本。" -ForegroundColor Red
        exit 1
    }
    Ok "opencode 安裝完成：$((Get-Command opencode).Source)"
}

# --- 3. 寫入設定 --------------------------------------------------------------
Step "3. 寫入 opencode 設定（provider：$Name）"
$cfgDir  = Join-Path $env:USERPROFILE ".config\opencode"
$cfgPath = Join-Path $cfgDir "opencode.json"
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

$cfg = $null
if (Test-Path $cfgPath) {
    Copy-Item $cfgPath "$cfgPath.bak" -Force
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Warn "舊設定無法解析，已備份成 opencode.json.bak 並重新建立" }
}
if (-not $cfg) { $cfg = [pscustomobject]@{ '$schema' = 'https://opencode.ai/config.json' } }

$modelMap = [ordered]@{}
foreach ($m in $served.data) {
    $ctx = $Context
    if ($m.max_model_len) { $ctx = [int]$m.max_model_len }
    $modelMap[$m.id] = [ordered]@{
        name      = "$($m.id) ($Name)"
        tool_call = $true
        # 輸出上限留在上下文的 1/4 以內，剩下給 opencode 的提示和程式碼
        limit     = [ordered]@{ context = $ctx; output = [Math]::Min(8192, [int][Math]::Floor($ctx / 4)) }
    }
}
$provider = [ordered]@{
    npm     = "@ai-sdk/openai-compatible"
    name    = $(if ($Label) { $Label } else { "vLLM ($Name)" })
    options = [ordered]@{ baseURL = $Url; apiKey = $Key }
    models  = $modelMap
}
if (-not $cfg.PSObject.Properties['provider']) {
    $cfg | Add-Member -NotePropertyName provider -NotePropertyValue ([pscustomobject]@{})
}
$cfg.provider | Add-Member -NotePropertyName $Name -NotePropertyValue $provider -Force

$first = "$Name/$($served.data[0].id)"
# 預設模型若指向這個 provider、但模型已不存在（筆電用 vllmctl 換過模型），自動改成新模型
$stale = $false
foreach ($p in 'model', 'small_model') {
    if ($cfg.PSObject.Properties[$p] -and "$($cfg.$p)" -like "$Name/*" -and
        -not $modelMap.Contains("$($cfg.$p)".Substring($Name.Length + 1))) { $stale = $true }
}
if ($stale) { Warn "原本的預設模型已不在筆電上，改成 $first" }
if ($Default -or $stale -or -not $cfg.PSObject.Properties['model']) {
    $cfg | Add-Member -NotePropertyName model -NotePropertyValue $first -Force
    $cfg | Add-Member -NotePropertyName small_model -NotePropertyValue $first -Force
}
# 存成無 BOM 的 UTF-8
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
Ok "設定檔：$cfgPath"
Ok "預設模型：$($cfg.model)"

# --- 4. 全域規則檔 ------------------------------------------------------------
Step "4. 安裝全域規則（$cfgDir\AGENTS.md）"
$rulesSrc = Join-Path $PSScriptRoot "opencode-rules.md"
$rulesDst = Join-Path $cfgDir "AGENTS.md"
if (-not (Test-Path $rulesSrc)) {
    Warn "找不到 opencode-rules.md，略過"
} elseif ((Test-Path $rulesDst) -and -not (Select-String -Path $rulesDst -Pattern "lab-opencode-rules" -Quiet)) {
    Warn "已經有自己的 AGENTS.md，不覆蓋（要改用實驗室版本請先刪除或改名它）"
} else {
    # 原樣複製（UTF-8 無 BOM），重新安裝時會更新成最新版
    [IO.File]::WriteAllBytes($rulesDst, [IO.File]::ReadAllBytes($rulesSrc))
    Ok "已安裝：回答用繁體中文、相對路徑、查資料附來源與日期、不捏造文獻"
}

if (-not $FromList) { Show-Usage }
exit 0   # 明確回傳成功：由 servers.json 逐台呼叫時靠 $LASTEXITCODE 判斷
