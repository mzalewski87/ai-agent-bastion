# =============================================================================
# AI Agent Bastion – Isolated GKE Port-Forward Tunnel Launcher (Windows PowerShell)
# - Isolates GCP project and KUBECONFIG to the current PowerShell session
# - Automatically verifies Google Cloud login and launches browser if expired
# - Supports networks with SSL/TLS inspection (Corporate VPN)
# - Automatically opens http://127.0.0.1:5050 in the default browser once live
# =============================================================================

$ErrorActionPreference = "Stop"

$DefaultPython = "$env:LOCALAPPDATA\Programs\Python\Python312-arm64\python.exe"
if (Test-Path -LiteralPath $DefaultPython) {
    $env:CLOUDSDK_PYTHON = $DefaultPython
}

$GcloudBin = "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin"
if ((Test-Path -LiteralPath $GcloudBin) -and ($env:PATH -notlike "*$GcloudBin*")) {
    $env:PATH = "$GcloudBin;$env:PATH"
}

$env:CLOUDSDK_CORE_DISABLE_SSL_VALIDATION = "1"

Write-Host "[1/4] Checking Google Cloud authentication status..." -ForegroundColor Cyan
$TokenValid = $false
try {
    $null = gcloud auth print-access-token 2>$null
    if ($LASTEXITCODE -eq 0) {
        $TokenValid = $true
    }
} catch {
    $TokenValid = $false
}

if (-not $TokenValid) {
    Write-Host "      No active Google Cloud session or token expired." -ForegroundColor Yellow
    Write-Host "      Launching default browser for 'gcloud auth login'..." -ForegroundColor Yellow
    gcloud auth login
} else {
    $ActiveAccount = (gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null | Select-Object -First 1)
    Write-Host "      Authenticated as: $ActiveAccount" -ForegroundColor Green
}

$ProjectId = $env:GCP_PROJECT_ID
if (-not $ProjectId) {
    $ProjectId = $env:CLOUDSDK_CORE_PROJECT
}
if (-not $ProjectId) {
    $ProjectId = (gcloud config get-value project 2>$null | Select-Object -First 1)
}
if ((-not $ProjectId) -or ($ProjectId -eq "(unset)")) {
    throw "GCP_PROJECT_ID is not set. Run: `$env:GCP_PROJECT_ID = 'your-gcp-project-id'` before launching."
}

$ClusterName = if ($env:GKE_CLUSTER) { $env:GKE_CLUSTER } else { "agent-bastion-gke" }
$Zone = if ($env:GKE_ZONE) { $env:GKE_ZONE } else { "us-central1-a" }
$Namespace = if ($env:K8S_NAMESPACE) { $env:K8S_NAMESPACE } else { "ai-agent-bastion" }
$ServiceName = if ($env:K8S_SERVICE) { $env:K8S_SERVICE } else { "ai-agent-bastion-svc" }
$LocalPort = if ($env:LOCAL_PORT) { [int]$env:LOCAL_PORT } else { 5050 }
$TargetUrl = "http://127.0.0.1:$LocalPort"

$env:CLOUDSDK_CORE_PROJECT = $ProjectId
$KubeDir = Join-Path $HOME ".kube"
if (-not (Test-Path -LiteralPath $KubeDir)) {
    New-Item -ItemType Directory -Path $KubeDir -Force | Out-Null
}
$env:KUBECONFIG = Join-Path $KubeDir "config-agent-bastion-gke"
$GkeContext = "gke_${ProjectId}_${Zone}_${ClusterName}"

Write-Host "[2/4] Fetching GKE cluster credentials ($ClusterName in $ProjectId) into isolated KUBECONFIG=$($env:KUBECONFIG)..." -ForegroundColor Cyan
try {
    gcloud container clusters get-credentials $ClusterName --zone $Zone --project $ProjectId
    if ($LASTEXITCODE -ne 0) { throw "get-credentials failed" }
} catch {
    Write-Host "      Reauthentication required. Launching default browser for 'gcloud auth login'..." -ForegroundColor Yellow
    gcloud auth login
    gcloud container clusters get-credentials $ClusterName --zone $Zone --project $ProjectId
}

Write-Host "[3/4] Configuring TLS bypass (--insecure-skip-tls-verify=true) for VPN SSL inspection..." -ForegroundColor Cyan
kubectl config unset "clusters.$GkeContext.certificate-authority-data" 2>$null | Out-Null
kubectl config set "clusters.$GkeContext.insecure-skip-tls-verify" true | Out-Null

# Stop any previous kubectl port-forward processes
Get-Process kubectl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Write-Host "[4/4] Starting Kubernetes port-forward tunnel: $TargetUrl -> svc/${ServiceName}:80 (namespace: $Namespace)..." -ForegroundColor Green
$KubectlExe = (Get-Command kubectl -ErrorAction Stop).Source
$TunnelProc = Start-Process -FilePath $KubectlExe -ArgumentList "--kubeconfig=$($env:KUBECONFIG)","--context=$GkeContext","--insecure-skip-tls-verify=true","port-forward","-n",$Namespace,"svc/$ServiceName","${LocalPort}:80","--address","127.0.0.1" -NoNewWindow -PassThru

$Connected = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $Resp = Invoke-WebRequest -Uri "$TargetUrl/health" -UseBasicParsing -TimeoutSec 2
        if ($Resp.StatusCode -eq 200) {
            $Connected = $true
            break
        }
    } catch {}
}

if ($Connected) {
    Write-Host "[READY] Tunnel connected successfully! Opening $TargetUrl in default browser..." -ForegroundColor Green
    Start-Process $TargetUrl | Out-Null
} else {
    Write-Host "[WARN] Tunnel started, but health check did not respond within 15s." -ForegroundColor Yellow
}

Write-Host "      Tunnel is active (PID: $($TunnelProc.Id)). Press Ctrl+C to stop." -ForegroundColor Cyan
Wait-Process -Id $TunnelProc.Id
