<#
.SYNOPSIS
  EKMAI-K8S 一鍵清除腳本

.DESCRIPTION
  反向停止並移除所有 EKMAI K8S 資源（保留 PVC 資料）

.PARAMETER DeleteData
  加上此參數會同時刪除 PVC（資料會遺失！）

.EXAMPLE
  .\scripts\teardown-all.ps1
  .\scripts\teardown-all.ps1 -DeleteData
#>
param(
    [switch]$DeleteData
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

Write-Host "========================================" -ForegroundColor Red
Write-Host " EKMAI-K8S Teardown" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red

# Reverse order of deployment
Write-Host "`n[1/6] Removing Gateway Ingress..." -ForegroundColor Yellow
kubectl delete -k "$root/base/gateway/" --ignore-not-found

Write-Host "`n[2/6] Removing Prometheus Stack..." -ForegroundColor Yellow
helm uninstall kube-prometheus -n ekmai-observe 2>$null

Write-Host "`n[3/6] Removing ELK Stack..." -ForegroundColor Yellow
kubectl delete -k "$root/base/observe/" --ignore-not-found

Write-Host "`n[4/6] Removing Wiki.js + Outline..." -ForegroundColor Yellow
kubectl delete -k "$root/base/kb/" --ignore-not-found

Write-Host "`n[5/6] Removing Mattermost..." -ForegroundColor Yellow
kubectl delete -k "$root/base/collab/" --ignore-not-found

Write-Host "`n[6/6] Removing Keycloak + APISIX..." -ForegroundColor Yellow
kubectl delete -k "$root/base/iam/" --ignore-not-found
helm uninstall apisix -n ekmai-gateway 2>$null

if ($DeleteData) {
    Write-Host "`n[!] Deleting PVCs (DATA WILL BE LOST)..." -ForegroundColor Red
    foreach ($ns in @("ekmai-gateway", "ekmai-iam", "ekmai-collab", "ekmai-kb", "ekmai-observe")) {
        kubectl delete pvc --all -n $ns 2>$null
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " EKMAI-K8S Teardown Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "`nNamespaces preserved. To delete: kubectl delete -f namespaces/namespaces.yaml"
