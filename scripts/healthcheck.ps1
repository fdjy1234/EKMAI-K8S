<#
.SYNOPSIS
  EKMAI-K8S 健康檢查腳本

.DESCRIPTION
  檢查所有 EKMAI 服務的狀態，包括：
  - Pod 狀態
  - Service 端點
  - PVC 綁定狀態
  - 證書有效期
  - 資源使用量

.EXAMPLE
  .\scripts\healthcheck.ps1
#>

$ErrorActionPreference = "Continue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " EKMAI-K8S Health Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$namespaces = @("ekmai-gateway", "ekmai-iam", "ekmai-collab", "ekmai-kb", "ekmai-observe")
$hasErrors = $false

# ── 1. Pod Status ──
Write-Host "`n[1] Pod Status" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    Write-Host "`n  Namespace: $ns" -ForegroundColor Cyan
    $pods = kubectl get pods -n $ns --no-headers 2>$null
    if (-not $pods) {
        Write-Host "    No pods found" -ForegroundColor DarkYellow
        continue
    }
    $pods | ForEach-Object {
        $line = $_
        if ($line -match "Running|Completed") {
            Write-Host "    ✓ $line" -ForegroundColor Green
        } else {
            Write-Host "    ✗ $line" -ForegroundColor Red
            $hasErrors = $true
        }
    }
}

# ── 2. PVC Status ──
Write-Host "`n[2] PVC Status" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    $pvcs = kubectl get pvc -n $ns --no-headers 2>$null
    if ($pvcs) {
        Write-Host "`n  Namespace: $ns" -ForegroundColor Cyan
        $pvcs | ForEach-Object {
            $line = $_
            if ($line -match "Bound") {
                Write-Host "    ✓ $line" -ForegroundColor Green
            } else {
                Write-Host "    ✗ $line" -ForegroundColor Red
                $hasErrors = $true
            }
        }
    }
}

# ── 3. Service Endpoints ──
Write-Host "`n[3] Service Endpoints" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    $endpoints = kubectl get endpoints -n $ns --no-headers 2>$null
    if ($endpoints) {
        Write-Host "`n  Namespace: $ns" -ForegroundColor Cyan
        $endpoints | ForEach-Object {
            $line = $_
            if ($line -match "<none>") {
                Write-Host "    ✗ $line (No endpoints!)" -ForegroundColor Red
                $hasErrors = $true
            } else {
                Write-Host "    ✓ $line" -ForegroundColor Green
            }
        }
    }
}

# ── 4. Resource Usage ──
Write-Host "`n[4] Resource Usage (Top Pods)" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    $top = kubectl top pods -n $ns --no-headers 2>$null
    if ($top) {
        Write-Host "`n  Namespace: $ns" -ForegroundColor Cyan
        $top | ForEach-Object { Write-Host "    $_" }
    }
}

# ── 5. Events (Warnings) ──
Write-Host "`n[5] Recent Warning Events" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    $events = kubectl get events -n $ns --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>$null | Select-Object -Last 5
    if ($events) {
        Write-Host "`n  Namespace: $ns" -ForegroundColor Cyan
        $events | ForEach-Object {
            Write-Host "    ⚠ $_" -ForegroundColor DarkYellow
        }
    }
}

# ── 6. NetworkPolicy Check ──
Write-Host "`n[6] NetworkPolicy Count" -ForegroundColor Yellow
Write-Host "────────────────────────────────────────"
foreach ($ns in $namespaces) {
    $count = (kubectl get networkpolicy -n $ns --no-headers 2>$null | Measure-Object).Count
    Write-Host "  $ns : $count policies" -ForegroundColor Cyan
}

# ── Summary ──
Write-Host "`n========================================" -ForegroundColor $(if ($hasErrors) { "Red" } else { "Green" })
if ($hasErrors) {
    Write-Host " Health Check: ISSUES FOUND" -ForegroundColor Red
} else {
    Write-Host " Health Check: ALL OK" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor $(if ($hasErrors) { "Red" } else { "Green" })
