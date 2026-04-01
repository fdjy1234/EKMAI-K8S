<#
.SYNOPSIS
  EKMAI-K8S 一鍵部署腳本

.DESCRIPTION
  依序部署所有 EKMAI 服務到 Kubernetes 叢集：
  1. Namespaces
  2. LimitRanges
  3. Default Network Policies
  4. Secrets（若 secrets/secrets.yaml 存在）
  5. APISIX (Helm)
  6. Keycloak (Kustomize)
  7. Mattermost + gitlab-proxy (Kustomize)
  8. Wiki.js + Outline (Kustomize)
  9. ELK Stack (ECK CRDs)
  10. Prometheus Stack (Helm)
  11. Gateway Ingress (Kustomize)
  + Environment Overlay + PodDisruptionBudgets

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
Write-Host "`n[1/11] Creating Namespaces..." -ForegroundColor Yellow
kubectl apply -f "$root/namespaces/namespaces.yaml"

# ── 2. LimitRanges ──
Write-Host "`n[2/11] Applying LimitRanges..." -ForegroundColor Yellow
kubectl apply -f "$root/base/security/namespace-security.yaml"

# ── 3. Default Network Policies ──
Write-Host "`n[3/11] Applying Default Network Policies..." -ForegroundColor Yellow
kubectl apply -f "$root/base/default-network-policies.yaml"

# ── 4. Secrets ──
$secretsFile = "$root/secrets/secrets.yaml"
if (Test-Path $secretsFile) {
    Write-Host "`n[4/11] Applying Secrets..." -ForegroundColor Yellow
    kubectl apply -f $secretsFile
} else {
    Write-Host "`n[4/11] SKIP — secrets/secrets.yaml not found" -ForegroundColor DarkYellow
    Write-Host "       Please copy secrets.example.yaml -> secrets.yaml and fill in values" -ForegroundColor DarkYellow
}

# ── 5. APISIX (Helm) ──
Write-Host "`n[5/11] Installing APISIX via Helm..." -ForegroundColor Yellow
helm repo add apisix https://charts.apiseven.com 2>$null
helm repo update
helm upgrade --install apisix apisix/apisix `
    --namespace ekmai-gateway `
    --values "$root/helm-values/apisix-values.yaml" `
    --wait --timeout 5m

# ── 6. Keycloak (Kustomize) ──
Write-Host "`n[6/11] Deploying Keycloak..." -ForegroundColor Yellow
kubectl apply -k "$root/base/iam/"

# ── 7. Mattermost (Kustomize) ──
Write-Host "`n[7/11] Deploying Mattermost..." -ForegroundColor Yellow
kubectl apply -k "$root/base/collab/"

# ── 8. Wiki.js + Outline (Kustomize) ──
Write-Host "`n[8/11] Deploying Wiki.js + Outline..." -ForegroundColor Yellow
kubectl apply -k "$root/base/kb/"

# ── 9. ECK Operator + ELK Stack ──
Write-Host "`n[9/11] Installing ECK Operator & ELK Stack..." -ForegroundColor Yellow
kubectl apply --server-side -f https://download.elastic.co/downloads/eck/2.14.0/crds.yaml 2>$null
kubectl apply -f https://download.elastic.co/downloads/eck/2.14.0/operator.yaml 2>$null
kubectl apply -k "$root/base/observe/"

# ── 10. Prometheus Stack (Helm) ──
Write-Host "`n[10/11] Installing Prometheus Stack via Helm..." -ForegroundColor Yellow
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>$null
helm repo update
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack `
    --namespace ekmai-observe `
    --values "$root/helm-values/prometheus-values.yaml" `
    --wait --timeout 5m

# ── 11. Gateway Ingress ──
Write-Host "`n[11/11] Applying Gateway Ingress..." -ForegroundColor Yellow
kubectl apply -k "$root/base/gateway/"

# ── 10. Apply Environment Overlay ──
if ($Environment -eq "prod") {
    Write-Host "`n[Overlay] Applying PROD overlay..." -ForegroundColor Magenta
    kubectl apply -k "$root/overlays/prod/"
} else {
    Write-Host "`n[Overlay] Applying DEV overlay..." -ForegroundColor Magenta
    kubectl apply -k "$root/overlays/dev/"
}

# ── PodDisruptionBudgets & Namespace security resources ──
Write-Host "`n[PDB/Security] Ensuring namespace security resources are applied..." -ForegroundColor Magenta
# `namespace-security.yaml` includes LimitRanges, default-deny NetworkPolicies, and PDBs
kubectl apply -f "$root/base/security/namespace-security.yaml"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " EKMAI-K8S Deploy Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nRun 'kubectl get pods -A' to check status."
Write-Host "Run 'kubectl get events -A --sort-by=.lastTimestamp' to check recent events."
