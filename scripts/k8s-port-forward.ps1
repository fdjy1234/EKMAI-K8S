Write-Host "======================================================"
Write-Host "Starting Port Forwarding for all EKMAI services"
Write-Host "======================================================"
Write-Host ""
Write-Host "[1] APISIX Dashboard    -> http://localhost:9000"
Write-Host "[2] APISIX Gateway      -> http://localhost:9080"
Write-Host "[3] Keycloak            -> http://localhost:8080"
Write-Host "[4] Mattermost          -> http://localhost:8065"
Write-Host "[5] Wiki.js             -> http://localhost:3000"
Write-Host "[6] Outline             -> http://localhost:3001"
Write-Host "[7] Kibana              -> http://localhost:5601"
Write-Host "[8] Grafana             -> http://localhost:3002"
Write-Host "[9] K8S Dashboard       -> http://localhost:8001/api/v1/..."
Write-Host ""
Write-Host "Fetching K8S Dashboard Admin Token..."
$token = kubectl -n kubernetes-dashboard create token admin-user 2>$null
if ($token) { Write-Host "Token: $token" } else { Write-Host "Dashboard not installed, skipping token." -ForegroundColor DarkYellow }
Write-Host ""
Write-Host "Starting processes in background (Press Ctrl+C to exit)..."

$jobs = @(
    @{ Name = "APISIX_UI";  Block = { kubectl port-forward svc/apisix-dashboard 9000:80 -n ekmai-gateway } },
    @{ Name = "APISIX_GW";  Block = { kubectl port-forward svc/apisix-gateway 9080:80 -n ekmai-gateway } },
    @{ Name = "KEYCLOAK";   Block = { kubectl port-forward svc/keycloak 8080:8080 -n ekmai-iam } },
    @{ Name = "MATTERMOST"; Block = { kubectl port-forward svc/mattermost-app 8065:8065 -n ekmai-collab } },
    @{ Name = "WIKIJS";     Block = { kubectl port-forward svc/wikijs-app 3000:3000 -n ekmai-kb } },
    @{ Name = "OUTLINE";    Block = { kubectl port-forward svc/outline-app 3001:3000 -n ekmai-kb } },
    @{ Name = "KIBANA";     Block = { kubectl port-forward svc/ekmai-kibana-kb-http 5601:5601 -n ekmai-observe } },
    @{ Name = "GRAFANA";    Block = { kubectl port-forward svc/kube-prometheus-grafana 3002:3000 -n ekmai-observe } },
    @{ Name = "K8S_UI";     Block = { kubectl proxy } }
)

foreach ($job in $jobs) {
    Start-Job -Name $job.Name -ScriptBlock $job.Block | Out-Null
}

try {
    while ($true) {
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host "Shutting down port forwarding..."
    $jobNames = $jobs | ForEach-Object { $_.Name }
    Stop-Job -Name $jobNames -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Name $jobNames -Force -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Done!"
}
