<#
.SYNOPSIS
  EKMAI-K8S PostgreSQL 備份腳本

.DESCRIPTION
  備份所有 EKMAI PostgreSQL 資料庫 (Keycloak, Mattermost, Wiki.js, Outline)

.PARAMETER BackupDir
  備份檔存放目錄（預設 ./backups）

.EXAMPLE
  .\scripts\backup-databases.ps1
  .\scripts\backup-databases.ps1 -BackupDir D:\backups
#>
param(
    [string]$BackupDir = "$PSScriptRoot\..\backups"
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " EKMAI-K8S Database Backup" -ForegroundColor Cyan
Write-Host " Timestamp: $timestamp" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$databases = @(
    @{ Name = "keycloak";    Namespace = "ekmai-iam";    Pod = "keycloak-db-0";    DB = "keycloak";    SecretName = "keycloak-db-secret" },
    @{ Name = "mattermost";  Namespace = "ekmai-collab"; Pod = "mattermost-db-0";  DB = "mattermost";  SecretName = "mattermost-db-secret" },
    @{ Name = "wikijs";      Namespace = "ekmai-kb";     Pod = "wikijs-db-0";      DB = "wiki";        SecretName = "wikijs-db-secret" },
    @{ Name = "outline";     Namespace = "ekmai-kb";     Pod = "outline-db-0";     DB = "outline";     SecretName = "outline-db-secret" }
)

$successCount = 0
$failCount = 0

foreach ($db in $databases) {
    $backupFile = Join-Path $BackupDir "$($db.Name)_$timestamp.sql.gz"
    Write-Host "`nBacking up $($db.Name)..." -ForegroundColor Yellow
    $attempt = 0
    $maxAttempts = 3
    $ok = $false
    while (-not $ok -and $attempt -lt $maxAttempts) {
        $attempt++
        try {
            # Read username/password from secret
            $uEnc = kubectl get secret $db.SecretName -n $db.Namespace -o jsonpath='{.data.username}' 2>$null
            $pEnc = kubectl get secret $db.SecretName -n $db.Namespace -o jsonpath='{.data.password}' 2>$null
            if ($uEnc) { $username = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($uEnc)) } else { $username = $db.Name }
            if ($pEnc) { $password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($pEnc)) } else { $password = "" }

            # Execute pg_dump inside pod with PGPASSWORD env and capture stdout
            $cmd = "/bin/sh -c \"PGPASSWORD='$password' pg_dump -U $username -d $($db.DB) --clean --if-exists --no-owner\""
            $dump = kubectl exec $db.Pod -n $db.Namespace -- $cmd 2>&1

            if (-not $dump) { throw "pg_dump returned empty output" }

            # Compress and write to .gz
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($dump)
            $fs = [System.IO.File]::Open($backupFile, [System.IO.FileMode]::Create)
            $gzip = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionMode]::Compress)
            $gzip.Write($bytes, 0, $bytes.Length)
            $gzip.Close()
            $fs.Close()

            if (Test-Path $backupFile) {
                $size = (Get-Item $backupFile).Length / 1KB
                Write-Host "  ✓ $($db.Name) -> $backupFile ($([math]::Round($size, 1)) KB)" -ForegroundColor Green
                $successCount++
                $ok = $true
            } else {
                throw "Failed to create backup file"
            }
        } catch {
            Write-Host "  Attempt $attempt: backup failed for $($db.Name): $_" -ForegroundColor Yellow
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (5 * $attempt) }
            else { Write-Host "  ✗ $($db.Name) backup failed after $maxAttempts attempts" -ForegroundColor Red; $failCount++ }
        }
    }
}

Write-Host "`n========================================" -ForegroundColor $(if ($failCount -gt 0) { "Yellow" } else { "Green" })
Write-Host " Backup Complete: $successCount success, $failCount failed" -ForegroundColor $(if ($failCount -gt 0) { "Yellow" } else { "Green" })
Write-Host " Backup Directory: $BackupDir" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor $(if ($failCount -gt 0) { "Yellow" } else { "Green" })
