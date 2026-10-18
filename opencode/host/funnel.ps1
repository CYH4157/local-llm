<#
=============================================================================
 funnel.ps1 — 用 Tailscale Funnel 把 vLLM 公開到網際網路（給校外的人用 opencode 連）

 最簡單：雙擊 funnel.cmd，輸入 on / off / status / test。
     on      開啟：https://<筆電名稱>.<tailnet>.ts.net/v1  →  本機 vLLM
     off     關閉（建議不用時就關）
     status  目前 Funnel 設定
     test    從外部網址測試：沒金鑰要被擋、有金鑰要能用、/v1 以外的路徑要 404

 安全設計：
   • 只公開 /v1 這個路徑。vLLM 的 API 金鑰只保護 /v1/*，/metrics 等路徑不用金鑰，
     所以不能把整個 8000 port 公開
   • HTTPS 憑證由 Tailscale 自動處理，金鑰與對話不會以明文在網路上傳送
   • 公開後「全世界都連得到網址」，安全全靠 API 金鑰：給校外的人之前建議 vllmctl new-key，
     用完就 off
 對方的電腦不用裝 Tailscale，只要網址與金鑰（client\install-client.cmd 貼上即可）。
=============================================================================
#>
param(
    [ValidateSet("on", "off", "status", "test")]
    [string]$Action = "status"
)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [X]  $m" -ForegroundColor Red; exit 1 }

# --- WSL 裡 vLLM 的埠號與金鑰 ---------------------------------------------
$Distro = "Ubuntu"
$df = Join-Path $ScriptDir "wsl-distro.txt"
if (Test-Path $df) { $Distro = (Get-Content $df -Raw).Trim() }
function Get-VllmVar([string]$name) {
    # 指令裡不能有雙引號（PowerShell 5.1 傳給 wsl.exe 會被吃掉）
    "$(wsl.exe -d $Distro -e bash -c ". ~/vllm-server/vllm.env 2>/dev/null; printf %s `$$name")".Trim()
}
$Port = Get-VllmVar "SERVE_PORT"
if (-not $Port) { $Port = "8000" }
$Target = "http://127.0.0.1:$Port/v1"

# --- 找到 Tailscale ---------------------------------------------------------
function Find-Tailscale {
    $c = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
    if (Test-Path $p) { return $p }
    return $null
}
$ts = Find-Tailscale
if (-not $ts) {
    if ($Action -ne "on") { Fail "尚未安裝 Tailscale（執行 funnel.cmd on 會引導安裝）" }
    Step "安裝 Tailscale"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "找不到 winget。請到 https://tailscale.com/download/windows 下載安裝後再執行一次。"
    }
    winget install --id Tailscale.Tailscale --silent --accept-source-agreements --accept-package-agreements
    $ts = Find-Tailscale
    if (-not $ts) { Fail "安裝後找不到 tailscale.exe，請重開終端機再執行一次。" }
    Ok "已安裝"
}

function Get-TsSelf {
    try { return (& $ts status --json | ConvertFrom-Json) } catch { return $null }
}
$st = Get-TsSelf
if (-not $st -or $st.BackendState -ne "Running") {
    Warn "Tailscale 還沒登入。請點右下角系統匣的 Tailscale 圖示 → Log in，用你的帳號登入，完成後再執行一次。"
    if ($Action -eq "on") { Start-Process (Join-Path $env:ProgramFiles "Tailscale\tailscale-ipn.exe") -ErrorAction SilentlyContinue }
    exit 1
}
$DnsName = "$($st.Self.DNSName)".TrimEnd(".")
$PublicUrl = "https://$DnsName/v1"

switch ($Action) {
    "status" {
        Step "Funnel 狀態"
        & $ts funnel status
        Write-Host ""
        Write-Host "  公開網址（開啟時）：$PublicUrl"
    }

    "off" {
        Step "關閉 Funnel"
        & $ts funnel --https=443 --set-path=/v1 off
        if ($LASTEXITCODE -ne 0) {
            Warn "關閉指令失敗；可改用 tailscale funnel reset（會清掉這台所有 serve/funnel 設定）"
            exit 1
        }
        Ok "已關閉，外部無法再連到 vLLM（校內區網不受影響）"
    }

    "on" {
        Step "檢查本機 vLLM"
        try { Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 5 | Out-Null; Ok "vLLM 正常（:$Port）" }
        catch { Warn "本機 vLLM 沒有回應；Funnel 仍會開啟，但要等 vLLM 啟動後才能用（vllmctl.cmd start）" }

        Step "開啟 Funnel（只公開 /v1）"
        Write-Host "  第一次使用時，Tailscale 會要你在瀏覽器按「同意啟用 Funnel」，按完會自動繼續。"
        & $ts funnel --bg --https=443 --set-path=/v1 $Target
        if ($LASTEXITCODE -ne 0) { Fail "開啟失敗，請看上方訊息（可能需要在 Tailscale 管理頁啟用 MagicDNS / HTTPS）" }
        Ok "已開啟（重開機後會自動恢復，直到執行 off）"

        # 確認路徑轉發正確：/v1/models 要轉到 vLLM 的 /v1/models。
        # Tailscale 若沒有去掉 /v1 前綴（變成 /v1/v1/models → 404），改成轉到 vLLM 根目錄。
        # 第一次要申請 HTTPS 憑證，前幾次可能連不上，所以重試一陣子
        $key = Get-VllmVar "SERVE_API_KEY"
        $code = $null
        foreach ($i in 1..12) {
            try { $code = [int](Invoke-WebRequest "https://$DnsName/v1/models" -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing -TimeoutSec 20).StatusCode }
            catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = $null } }
            if ($code) { break }
            Start-Sleep 5
        }
        if ($code -eq 404) {
            Warn "路徑轉發需要調整，改用 http://127.0.0.1:$Port 重新設定…"
            & $ts funnel --https=443 --set-path=/v1 off | Out-Null
            & $ts funnel --bg --https=443 --set-path=/v1 "http://127.0.0.1:$Port"
        }
        if ($code) { Ok "轉發檢查完成（可再執行 funnel.cmd test 做完整檢查）" }
        else { Warn "HTTPS 憑證可能還在申請中，幾分鐘後執行 funnel.cmd test 檢查" }

        Write-Host ""
        Write-Host "  給校外使用者（對方不用裝 Tailscale）：" -ForegroundColor Cyan
        Write-Host "    網址：$PublicUrl"
        Write-Host "    金鑰：在 vllmctl.cmd 輸入 info 查看（建議先 new-key 換一組再給）"
        Write-Host "    安裝：雙擊 client\install-client.cmd，貼上網址與金鑰"
        Write-Host ""
        Warn "第一次開啟時，公開 DNS 最多要 10 分鐘才生效。之後可執行 funnel.cmd test 檢查。"
    }

    "test" {
        Step "測試 $PublicUrl"
        Write-Host "  （在本機測試會走 Tailscale 內部網路；要確認真的公開，請用手機關 Wi-Fi 開瀏覽器連 $PublicUrl/models，看到 401 即可）"
        $key = Get-VllmVar "SERVE_API_KEY"
        function Get-Code([string]$url, [hashtable]$headers = @{}) {
            try { return [int](Invoke-WebRequest $url -Headers $headers -UseBasicParsing -TimeoutSec 20).StatusCode }
            catch {
                if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
                return "連不到（$($_.Exception.Message)）"
            }
        }
        $root = "https://$DnsName"
        $checks = @(
            @{ Name = "沒帶金鑰要被擋（401）";        Url = "$root/v1/models"; Headers = @{};                                  Want = 401 },
            @{ Name = "帶金鑰可以用（200）";          Url = "$root/v1/models"; Headers = @{ Authorization = "Bearer $key" }; Want = 200 },
            @{ Name = "/metrics 不能公開（404）";      Url = "$root/metrics";   Headers = @{};                                  Want = 404 },
            @{ Name = "/health 不能公開（404）";       Url = "$root/health";    Headers = @{};                                  Want = 404 }
        )
        $allOk = $true
        foreach ($c in $checks) {
            $code = Get-Code $c.Url $c.Headers
            if ($code -eq $c.Want) { Ok "$($c.Name)：$code" } else { Warn "$($c.Name)：得到 $code"; $allOk = $false }
        }
        if ($allOk) { Ok "全部正常" } else { Warn "有項目不符合預期：先 funnel.cmd status 確認只公開 /v1，必要時 off 後重新 on" }
    }
}
