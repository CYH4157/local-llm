<#
    deploy.ps1 — Discord Bot 部署（模型用 opencode 專案在 WSL 架設的 vLLM）

    前提：已經用 server\wsl2\setup-host.cmd 架好 vLLM（:8000）
    做的事：
        1. 找到 opencode 的 vLLM，確認服務正常、讀得到 API 金鑰
        2. 停用舊版自己架的 llama-swap（避免兩套 vLLM 搶同一張顯卡）
        3. 建立 Discord bot 的 Python 環境
        4. 產生 / 更新 .env

    用法：
        cd C:\Users\a9756\Documents\llm\local-llm
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1
        # 不是從本 repo 執行時，指定 repo 根目錄：
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -RepoDir D:\local-llm
#>

param(
    [string]$RepoDir = "",
    [string]$Distro = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# 本檔在 repo 的 discord\client，往上兩層就是 repo 根目錄
if (-not $RepoDir) { $RepoDir = [IO.Path]::GetFullPath((Join-Path $ScriptDir "..\..")) }

function Write-Step($m){ Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "  [OK] $m"     -ForegroundColor Green }
function Write-Warn2($m){Write-Host "  [!]  $m"     -ForegroundColor Yellow }
function Test-Command($n){ return [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Refresh-Path {
    $m=[System.Environment]::GetEnvironmentVariable("Path","Machine")
    $u=[System.Environment]::GetEnvironmentVariable("Path","User")
    $env:Path="$m;$u"
}
$Utf8NoBom = New-Object Text.UTF8Encoding $false
function Set-EnvValue($file, $key, $value) {
    $lines = @([IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$key=") { $lines[$i] = "$key=$value"; $found = $true }
    }
    if (-not $found) { $lines += "$key=$value" }
    [IO.File]::WriteAllLines($file, [string[]]$lines, $Utf8NoBom)
}

# --- 1. 找到 opencode 的 vLLM -----------------------------------------------
Write-Step "1. 檢查 opencode 專案的 vLLM"
if (-not $Distro) {
    $df = Join-Path $RepoDir "server\wsl2\wsl-distro.txt"
    $Distro = if (Test-Path $df) { (Get-Content $df -Raw).Trim() } else { "Ubuntu" }
}
Write-Ok "WSL 發行版：$Distro"

# 指令裡不能有雙引號（PowerShell 5.1 傳給 wsl.exe 會被吃掉）
$vars = "$(wsl.exe -d $Distro -e bash -c '. ~/vllm-server/vllm.env 2>/dev/null; printf %s,%s ${SERVE_PORT:-8000} $SERVE_API_KEY')".Trim()
$port, $key = $vars -split ',', 2
if (-not $key) {
    throw "在 WSL（$Distro）找不到 ~/vllm-server/vllm.env。請先執行 server\wsl2\setup-host.cmd 架好 vLLM。"
}
if (-not $port) { $port = "8000" }
$BaseUrl = "http://127.0.0.1:$port/v1"
try {
    $models = Invoke-RestMethod "$BaseUrl/models" -TimeoutSec 15 -Headers @{ Authorization = "Bearer $key" }
    $m = $models.data[0]
    Write-Ok "vLLM 正常：$($m.id)（上下文 $($m.max_model_len)）  $BaseUrl"
} catch {
    Write-Warn2 "vLLM 目前沒有回應（$($_.Exception.Message)）"
    Write-Warn2 "設定照樣完成；請雙擊 server\wsl2\vllmctl.cmd 輸入 status / start"
}

# --- 2. 停用舊版 llama-swap -------------------------------------------------
Write-Step "2. 檢查舊版 llama-swap"
$old = "$(wsl.exe -d $Distro -e bash -c 'systemctl is-enabled llama-swap 2>/dev/null || true')".Trim()
if ($old -and $old -ne "not-found") {
    Write-Warn2 "發現舊版 llama-swap 服務（$old），停用中以釋放顯卡（可能要輸入 Ubuntu 密碼）…"
    wsl.exe -d $Distro -e bash -c "sudo systemctl disable --now llama-swap"
    Write-Ok "已停用（~/llm 資料夾不再使用，可自行刪除）"
} else {
    Write-Ok "沒有舊版服務"
}

# --- 3. 安裝 uv + bot 的 Python 環境 ----------------------------------------
Write-Step "3. 建立 Discord bot 的 Python 環境"
if (-not (Test-Command "uv")) {
    if (-not (Test-Command "winget")) { throw "找不到 winget，請手動安裝 uv：https://docs.astral.sh/uv/" }
    winget install --id astral-sh.uv --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Test-Command "uv")) { throw "uv 裝完找不到指令，請重開 PowerShell 再跑一次。" }
}
Push-Location $ScriptDir
if (-not (Test-Path ".venv\Scripts\python.exe")) { uv venv --python 3.11 .venv }
uv pip install --python (Join-Path $ScriptDir ".venv\Scripts\python.exe") -r (Join-Path $ScriptDir "requirements.txt")
Pop-Location
Write-Ok "套件安裝完成"

# --- 4. .env ----------------------------------------------------------------
Write-Step "4. 設定檔 .env"
$envFile = Join-Path $ScriptDir ".env"
$example = Join-Path $ScriptDir ".env.example"
if (-not (Test-Path $envFile)) {
    Copy-Item $example $envFile
    Write-Ok "已建立 .env（記得填入 DISCORD_BOT_TOKEN）"
} else {
    # 舊版 .env 升級：補上新設定，已有的不動
    $have = [IO.File]::ReadAllLines($envFile, [Text.Encoding]::UTF8) | ForEach-Object { ($_ -split '=', 2)[0].Trim() }
    $added = @()
    foreach ($line in [IO.File]::ReadAllLines($example, [Text.Encoding]::UTF8)) {
        if ($line -match '^\s*([A-Z_]+)=' -and $have -notcontains $Matches[1]) { $added += $line }
    }
    if ($added.Count -gt 0) {
        [IO.File]::AppendAllLines($envFile, [string[]](@("", "# === 以下為更新時自動補上 ===") + $added), $Utf8NoBom)
        Write-Ok ".env 已補上：$(($added | ForEach-Object { ($_ -split '=')[0] }) -join ', ')"
    }
}
Set-EnvValue $envFile "LLM_BASE_URL" $BaseUrl
Set-EnvValue $envFile "WSL_DISTRO" $Distro
# 金鑰留空 = bot 自動從 WSL 讀（vllmctl new-key 換金鑰後也不用改）；舊版 llama-swap 的金鑰一併清掉
Set-EnvValue $envFile "LLM_API_KEY" ""
Write-Ok "LLM_BASE_URL=$BaseUrl、WSL_DISTRO=$Distro、LLM_API_KEY 留空（自動從 WSL 讀取）"

# --- 完成 -------------------------------------------------------------------
Write-Step "完成！"
Write-Host ""
Write-Host "  1) .env 填好 DISCORD_BOT_TOKEN（建立 bot 的步驟見 README）" -ForegroundColor Cyan
Write-Host "  2) 啟動 bot：雙擊 start-bot.bat" -ForegroundColor Cyan
Write-Host "  3) 開機自動啟動：以系統管理員執行 install-autostart.ps1" -ForegroundColor Cyan
Write-Host ""
