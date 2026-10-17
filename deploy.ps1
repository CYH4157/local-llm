<#
    deploy.ps1 — 本地端 LLM（vLLM + llama-swap on WSL2）+ Discord Bot 部署

    做的事：
        1. 產生 / 補齊 .env 設定檔（含自動產生 API 金鑰）
        2. 檢查 WSL2 / Ubuntu 與 GPU
        3. 在 WSL 裡安裝 vLLM + llama-swap，註冊成開機自動啟動的服務（:8080）
        4. 在 Windows 建立 Discord bot 的 Python 環境

    前提：已經裝好 WSL2 + Ubuntu（沒裝的話本腳本會告訴你怎麼裝）

    用法：
        cd C:\Users\a9756\Documents\llm\local-llm
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1
        # 只更新 bot、不動 WSL 端：
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -SkipWsl
        # 不要預先下載模型（之後第一次提問才下載）：
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -SkipWarmup
#>

param(
    [string]$Distro = "Ubuntu",
    [string]$DefaultModel = "qwen3-8b",
    [switch]$SkipWsl,
    [switch]$SkipWarmup
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($m){ Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "  [OK] $m"     -ForegroundColor Green }
function Write-Warn2($m){Write-Host "  [!]  $m"     -ForegroundColor Yellow }
function Test-Command($n){ return [bool](Get-Command $n -ErrorAction SilentlyContinue) }
function Refresh-Path {
    $m=[System.Environment]::GetEnvironmentVariable("Path","Machine")
    $u=[System.Environment]::GetEnvironmentVariable("Path","User")
    $env:Path="$m;$u"
}
function Get-EnvValue($file, $key) {
    $line = Get-Content $file -Encoding UTF8 | Where-Object { $_ -match "^\s*$key=" } | Select-Object -First 1
    if ($line) { return ($line -split '=', 2)[1].Trim() } else { return "" }
}

# --- 0. 前置檢查 ------------------------------------------------------------
Write-Step "0. 前置檢查"
if (Test-Command "nvidia-smi") {
    Write-Ok "GPU：$((nvidia-smi --query-gpu=name,memory.total --format=csv,noheader) 2>$null)"
} else {
    throw "找不到 nvidia-smi：請先安裝最新版 NVIDIA 顯示卡驅動（vLLM 需要 NVIDIA GPU）。"
}

# --- 1. 產生 / 補齊 .env ----------------------------------------------------
Write-Step "1. 設定檔"
$envFile = Join-Path $ScriptDir ".env"
$example = Join-Path $ScriptDir ".env.example"
if (-not (Test-Path $envFile)) {
    Copy-Item $example $envFile
    (Get-Content $envFile -Encoding UTF8) -replace '^DEFAULT_MODEL=.*', "DEFAULT_MODEL=$DefaultModel" |
        Set-Content $envFile -Encoding UTF8
    Write-Ok "已建立 .env（記得填入 DISCORD_BOT_TOKEN）"
} else {
    # 舊版（Ollama）.env 升級：把新版才有的設定補在最後，已有的不動
    $have = (Get-Content $envFile -Encoding UTF8) | ForEach-Object { ($_ -split '=', 2)[0].Trim() }
    $added = @()
    foreach ($line in (Get-Content $example -Encoding UTF8)) {
        if ($line -match '^\s*([A-Z_]+)=') {
            $key = $Matches[1]
            if ($have -notcontains $key) {
                if ($key -eq "DEFAULT_MODEL") { $line = "DEFAULT_MODEL=$DefaultModel" }
                $added += $line
            }
        }
    }
    if ($added.Count -gt 0) {
        Add-Content $envFile -Encoding UTF8 -Value (@("", "# === 以下為升級 vLLM 版時自動補上 ===") + $added)
        Write-Ok ".env 已補上：$(($added | ForEach-Object { ($_ -split '=')[0] }) -join ', ')"
    } else {
        Write-Ok ".env 已是最新"
    }
}

# API 金鑰：.env 沒有就自動產生一組（bot 與 llama-swap 共用）
$ApiKey = Get-EnvValue $envFile "LLM_API_KEY"
if (-not $ApiKey) {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $ApiKey = "sk-lab-" + (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    (Get-Content $envFile -Encoding UTF8) -replace '^\s*LLM_API_KEY=.*', "LLM_API_KEY=$ApiKey" |
        Set-Content $envFile -Encoding UTF8
    Write-Ok "已產生 API 金鑰並寫入 .env 的 LLM_API_KEY"
} else {
    Write-Ok "使用 .env 裡現有的 API 金鑰"
}
if ($ApiKey -notmatch '^[A-Za-z0-9_\-]+$') { throw "LLM_API_KEY 只能包含英數字、- 和 _" }

# --- 2. WSL 端：vLLM + llama-swap -------------------------------------------
if ($SkipWsl) {
    Write-Step "2. WSL 端（略過）"
} else {
    Write-Step "2. 檢查 WSL2 / $Distro"
    $distros = @()
    try { $distros = (wsl.exe -l -q) -replace "`0", "" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } } catch {}
    if ($distros -notcontains $Distro) {
        Write-Warn2 "找不到 WSL 的 $Distro。請："
        Write-Host  "     1) 以『系統管理員』開 PowerShell 執行： wsl --install -d $Distro"
        Write-Host  "     2) 重新開機，依提示設定 Ubuntu 使用者名稱與密碼"
        Write-Host  "     3) 再執行一次本腳本"
        exit 1
    }
    Write-Ok "$Distro 已安裝"

    Write-Step "3. 在 WSL 安裝 vLLM + llama-swap（會要求輸入 Ubuntu 密碼）"
    $wslDir = (wsl.exe -d $Distro -e wslpath -a ($ScriptDir + "\wsl")).Trim()
    $skip = if ($SkipWarmup) { "1" } else { "0" }
    # 先轉成 LF 換行再執行，避免 Git 在 Windows 把 .sh 轉成 CRLF 造成 bash 錯誤
    $cmd = "tr -d '\r' < '$wslDir/setup-wsl.sh' > /tmp/setup-wsl.sh && SRC_DIR='$wslDir' DEFAULT_MODEL='$DefaultModel' SKIP_WARMUP='$skip' LLAMA_SWAP_API_KEY='$ApiKey' bash /tmp/setup-wsl.sh"
    wsl.exe -d $Distro -e bash -c $cmd
    if ($LASTEXITCODE -eq 2) {
        Write-Warn2 "剛開啟 WSL 的 systemd，需要重啟 WSL（會關閉所有 WSL 視窗）…"
        wsl.exe --shutdown
        Start-Sleep 5
        wsl.exe -d $Distro -e bash -c $cmd
    }
    if ($LASTEXITCODE -ne 0) { throw "WSL 端安裝失敗（exit $LASTEXITCODE），請看上方訊息。" }
    Write-Ok "WSL 端完成"
}

# --- 4. 安裝 uv（Python 管理器）--------------------------------------------
Write-Step "4. 安裝 uv（Python 管理器）"
if (Test-Command "uv") { Write-Ok "uv 已安裝" }
else {
    if (-not (Test-Command "winget")) { throw "找不到 winget，請手動安裝 uv：https://docs.astral.sh/uv/" }
    winget install --id astral-sh.uv --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Test-Command "uv")) { throw "uv 裝完找不到指令，請重開 PowerShell 再跑一次。" }
    Write-Ok "uv 安裝完成"
}

# --- 5. 建立 bot 的 Python 環境 --------------------------------------------
Write-Step "5. 建立 Discord bot 的 Python 環境"
Push-Location $ScriptDir
if (-not (Test-Path ".venv\Scripts\python.exe")) { uv venv --python 3.11 .venv }
$venvPy = Join-Path $ScriptDir ".venv\Scripts\python.exe"
uv pip install --python $venvPy -r (Join-Path $ScriptDir "requirements.txt")
Pop-Location
Write-Ok "套件安裝完成"

# --- 6. 連線測試 ------------------------------------------------------------
Write-Step "6. 測試 Windows → WSL 模型服務"
try {
    $models = Invoke-RestMethod "http://127.0.0.1:8080/v1/models" -TimeoutSec 10 `
              -Headers @{ Authorization = "Bearer $ApiKey" }
    Write-Ok "可用模型：$(($models.data | ForEach-Object { $_.id }) -join ', ')"
} catch {
    Write-Warn2 "連不到 http://127.0.0.1:8080（$($_.Exception.Message)）"
    Write-Warn2 "檢查：wsl -d $Distro -e systemctl status llama-swap"
}

# --- 完成 -------------------------------------------------------------------
Write-Step "完成！"
Write-Host ""
Write-Host "  1) .env 填好 DISCORD_BOT_TOKEN（建立 bot 的步驟見 README）" -ForegroundColor Cyan
Write-Host "  2) 啟動 bot：雙擊 start-bot.bat" -ForegroundColor Cyan
Write-Host "  3) 正式使用：以系統管理員執行 install-autostart.ps1（開機自動啟動 WSL 服務 + bot）" -ForegroundColor Cyan
Write-Host ""
