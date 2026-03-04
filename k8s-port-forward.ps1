Write-Host "======================================================"
Write-Host "Starting Port Forwarding for APISIX and K8S Dashboard"
Write-Host "======================================================"
Write-Host ""
Write-Host "[1] APISIX Dashboard"
Write-Host "    -> URL: http://localhost:9000"
Write-Host "    -> User: admin / Pass: admin"
Write-Host ""
Write-Host "[2] APISIX Gateway"
Write-Host "    -> URL: http://localhost:9080"
Write-Host ""
Write-Host "[3] Kubernetes Dashboard"
Write-Host "    -> URL: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
Write-Host ""
Write-Host "Fetching K8S Dashboard Admin Token..."
$token = kubectl -n kubernetes-dashboard create token admin-user
Write-Host "Token: $token"
Write-Host ""
Write-Host "Starting processes in background (Press Ctrl+C to exit this script)..."

# Start port forwarding jobs
Start-Job -Name APISIX_UI -ScriptBlock { kubectl port-forward svc/apisix-dashboard 9000:80 -n ekmai-gateway } | Out-Null
Start-Job -Name APISIX_GW -ScriptBlock { kubectl port-forward svc/apisix-gateway 9080:80 -n ekmai-gateway } | Out-Null
Start-Job -Name K8S_UI -ScriptBlock { kubectl proxy } | Out-Null

try {
    # Keep script running
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host "Shutting down port forwarding..."
    Stop-Job -Name APISIX_UI, APISIX_GW, K8S_UI | Out-Null
    Remove-Job -Name APISIX_UI, APISIX_GW, K8S_UI -Force | Out-Null
    Write-Host "Done!"
}
