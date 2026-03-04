<#
.SYNOPSIS
  EKMAI-K8S 一鍵部署腳本

.DESCRIPTION
  依序部署所有 EKMAI 服務到 Kubernetes 叢集：
  1. Namespaces
  2. Secrets（若 secrets/secrets.yaml 存在）
  3. APISIX (Helm)
  4. Keycloak (Kustomize)
  5. Mattermost + gitlab-proxy (Kustomize)
  6. Wiki.js + Outline (Kustomize)
  7. ELK Stack (ECK CRDs)
  8. Prometheus Stack (Helm)
  9. Gateway Ingress (Kustomize)

.PARAMETER Environment
  部署環境：dev 或 prod（預設 dev）

.EXAMPLE
  .\scripts\deploy-all.ps1
  .\scripts\deploy-all.ps1 -Environment prod
#>
param(
    [ValidateSet("dev", "prod")]
    [string]$Environment = "dev"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " EKMAI-K8S Deploy — Environment: $Environment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ── 1. Namespaces ──
Write-Host "`n[1/9] Creating Namespaces..." -ForegroundColor Yellow
kubectl apply -f "$root/namespaces/namespaces.yaml"

# ── 2. Secrets ──
$secretsFile = "$root/secrets/secrets.yaml"
if (Test-Path $secretsFile) {
    Write-Host "`n[2/9] Applying Secrets..." -ForegroundColor Yellow
    kubectl apply -f $secretsFile
} else {
    Write-Host "`n[2/9] SKIP — secrets/secrets.yaml not found" -ForegroundColor DarkYellow
    Write-Host "       Please copy secrets.example.yaml -> secrets.yaml and fill in values" -ForegroundColor DarkYellow
}

# ── 3. APISIX (Helm) ──
Write-Host "`n[3/9] Installing APISIX via Helm..." -ForegroundColor Yellow
helm repo add apisix https://charts.apiseven.com 2>$null
helm repo update
helm upgrade --install apisix apisix/apisix `
    --namespace ekmai-gateway `
    --values "$root/helm-values/apisix-values.yaml" `
    --wait --timeout 5m

# ── 4. Keycloak (Kustomize) ──
Write-Host "`n[4/9] Deploying Keycloak..." -ForegroundColor Yellow
kubectl apply -k "$root/base/iam/"

# ── 5. Mattermost (Kustomize) ──
Write-Host "`n[5/9] Deploying Mattermost..." -ForegroundColor Yellow
kubectl apply -k "$root/base/collab/"

# ── 6. Wiki.js + Outline (Kustomize) ──
Write-Host "`n[6/9] Deploying Wiki.js + Outline..." -ForegroundColor Yellow
kubectl apply -k "$root/base/kb/"

# ── 7. ECK Operator + ELK Stack ──
Write-Host "`n[7/9] Installing ECK Operator & ELK Stack..." -ForegroundColor Yellow
kubectl create -f https://download.elastic.co/downloads/eck/2.14.0/crds.yaml 2>$null
kubectl apply -f https://download.elastic.co/downloads/eck/2.14.0/operator.yaml 2>$null
kubectl apply -k "$root/base/observe/"

# ── 8. Prometheus Stack (Helm) ──
Write-Host "`n[8/9] Installing Prometheus Stack via Helm..." -ForegroundColor Yellow
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
helm repo update
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack `
    --namespace ekmai-observe `
    --values "$root/helm-values/prometheus-values.yaml" `
    --wait --timeout 5m

# ── 9. Gateway Ingress ──
Write-Host "`n[9/9] Applying Gateway Ingress..." -ForegroundColor Yellow
kubectl apply -k "$root/base/gateway/"

# ── 10. Apply Environment Overlay ──
if ($Environment -eq "prod") {
    Write-Host "`n[Overlay] Applying PROD overlay..." -ForegroundColor Magenta
    kubectl apply -k "$root/overlays/prod/"
} else {
    Write-Host "`n[Overlay] Applying DEV overlay..." -ForegroundColor Magenta
    kubectl apply -k "$root/overlays/dev/"
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " EKMAI-K8S Deploy Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nRun 'kubectl get pods -A' to check status."
