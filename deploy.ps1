<#
    deploy.ps1 — 本地端 LLM + Discord Bot 部署（Windows 原生）

    做的事：
        1. 安裝 Ollama（模型引擎，開機自動啟動）
        2. 下載模型（預設 qwen2.5:14b）
        3. 建立 Python 環境 + 安裝 Discord bot 需要的套件
        4. 產生 .env 設定檔（你再把 Discord token 填進去）

    不含 Open WebUI；聊天介面改用 Discord。

    用法：
        cd C:\Users\a9756\Documents\llm\local-llm
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1
        # 想省流量用小模型：
        powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Model "qwen2.5:7b"
#>

param(
    [string]$Model = "qwen2.5:14b"
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

# --- 0. 前置檢查 ------------------------------------------------------------
Write-Step "0. 前置檢查"
if (-not (Test-Command "winget")) {
    throw "找不到 winget。請更新『App Installer』或手動到 https://ollama.com/download 裝 Ollama。"
}
Write-Ok "winget 可用"
if (Test-Command "nvidia-smi") {
    Write-Ok "GPU：$((nvidia-smi --query-gpu=name,memory.total --format=csv,noheader) 2>$null)"
} else {
    Write-Warn2 "找不到 nvidia-smi，將以 CPU 執行（較慢）。"
}

# --- 1. 安裝 Ollama ---------------------------------------------------------
Write-Step "1. 安裝 Ollama"
if (Test-Command "ollama") {
    Write-Ok "已安裝：$((ollama --version) 2>$null)"
} else {
    winget install --id Ollama.Ollama --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Test-Command "ollama")) { throw "Ollama 裝完找不到指令，請重開 PowerShell 再跑一次。" }
    Write-Ok "Ollama 安裝完成"
}

# 讓區網也能連（給 bot / 其他機器用），並確保服務在跑
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST","0.0.0.0:11434","User")
$env:OLLAMA_HOST="0.0.0.0:11434"
Get-Process "ollama*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
$ready=$false
foreach ($i in 1..30){ try{ Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2|Out-Null;$ready=$true;break }catch{ Start-Sleep 1 } }
if($ready){ Write-Ok "Ollama API 就緒 (11434)" } else { Write-Warn2 "API 尚未回應，稍後可手動 'ollama serve'" }

# --- 2. 下載模型 ------------------------------------------------------------
Write-Step "2. 下載模型：$Model（首次約 5~9GB）"
ollama pull $Model
Write-Ok "模型就緒"

# --- 3. 安裝 uv（Python 管理器）--------------------------------------------
Write-Step "3. 安裝 uv（Python 管理器）"
if (Test-Command "uv") { Write-Ok "uv 已安裝" }
else {
    winget install --id astral-sh.uv --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Test-Command "uv")) { throw "uv 裝完找不到指令，請重開 PowerShell 再跑一次。" }
    Write-Ok "uv 安裝完成"
}

# --- 4. 建立 bot 的 Python 環境 --------------------------------------------
Write-Step "4. 建立 Discord bot 的 Python 環境"
Push-Location $ScriptDir
uv venv --python 3.11 .venv
$venvPy = Join-Path $ScriptDir ".venv\Scripts\python.exe"
uv pip install --python $venvPy -r (Join-Path $ScriptDir "requirements.txt")
Pop-Location
Write-Ok "套件安裝完成"

# --- 5. 產生 .env ----------------------------------------------------------
Write-Step "5. 設定檔"
$envFile = Join-Path $ScriptDir ".env"
if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $ScriptDir ".env.example") $envFile
    # 把模型名稱寫進去
    (Get-Content $envFile) -replace '^MODEL=.*', "MODEL=$Model" | Set-Content $envFile -Encoding UTF8
    Write-Ok "已建立 .env（記得填入 DISCORD_BOT_TOKEN）"
} else {
    Write-Ok ".env 已存在，未覆蓋"
}

# --- 完成 -------------------------------------------------------------------
Write-Step "完成！接下來手動 3 步"
Write-Host ""
Write-Host "  1) 建立 Discord Bot 拿 Token：" -ForegroundColor Cyan
Write-Host "     https://discord.com/developers/applications → New Application"
Write-Host "     → Bot → Reset Token 複製；並開啟『MESSAGE CONTENT INTENT』"
Write-Host "     → OAuth2 → URL Generator 勾 bot，權限勾 Send Messages/Read Message History，"
Write-Host "        用產生的網址把 bot 邀進你的伺服器"
Write-Host ""
Write-Host "  2) 把 Token 填進設定檔：" -ForegroundColor Cyan
Write-Host "     記事本開啟 $envFile，填 DISCORD_BOT_TOKEN=你的token"
Write-Host ""
Write-Host "  3) 啟動 bot：" -ForegroundColor Cyan
Write-Host "     powershell -ExecutionPolicy Bypass -File `"$($ScriptDir)\run-bot.ps1`""
Write-Host "     想開機自動啟動： …\install-autostart.ps1"
Write-Host ""
