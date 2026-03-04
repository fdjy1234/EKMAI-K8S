# 從 Docker Compose 遷移到 Kubernetes

本文件說明如何從原始 [EKMAI](https://github.com/fdjy1234/EKMAI) Docker Compose 專案遷移到本 Kubernetes 專案。

---

## 概念對照

| Docker Compose | Kubernetes | 本專案位置 |
|---|---|---|
| `services:` | Deployment / StatefulSet | `base/*/` |
| `image:` | `spec.containers[].image` | 同上 |
| `ports:` | Service + Ingress | `base/gateway/ingress.yaml` |
| `volumes:` (named) | PersistentVolumeClaim | 各 `*.yaml` 中 |
| `volumes:` (bind mount) | ConfigMap / Secret | `base/kb/outline-config.yaml` 等 |
| `environment:` | `env:` / `envFrom:` | 各 Deployment 中 |
| `.env` 檔案 | K8S Secret | `secrets/secrets.example.yaml` |
| `depends_on:` | initContainers | 各 Deployment 的 `wait-for-*` |
| `healthcheck:` | readinessProbe / livenessProbe | 各 Deployment 中 |
| `ekmai-net` | K8S Namespace 內建互通 | `namespaces/namespaces.yaml` |
| `docker-compose.prod.yml` | Kustomize overlay | `overlays/prod/` |

---

## 遷移步驟

### 1. 準備 K8S 環境
```powershell
# 啟用 Docker Desktop K8S 或安裝 minikube / k3s
kubectl cluster-info
```

### 2. 同步設定
將原始專案的 `.env` 檔案中的值填入 `secrets/secrets.yaml`：
- `apisix/.env` → `secrets.example.yaml` 中的 APISIX 部分（已整合至 Helm values）
- `keycloak/.env` → `keycloak-db-secret`, `keycloak-admin-secret`
- `Mattermost/.env` → `mattermost-db-secret`
- `outline/.env` → `outline-secrets`, `outline-db-secret`
- `elk/.env` → `elk-secrets`

### 3. 遷移 TLS 證書
```powershell
kubectl create secret tls ekmai-tls-cert \
  --cert=../EKMAI/infra/cert.pem \
  --key=../EKMAI/infra/key.pem \
  -n ekmai-gateway

kubectl create secret generic ekmai-root-ca \
  --from-file=ski-Root-CA.pem=../EKMAI/infra/ski-Root-CA.pem \
  -n ekmai-gateway
```

### 4. 部署
```powershell
.\scripts\deploy-all.ps1
```

### 5. 驗證
```powershell
kubectl get pods -A | Select-String ekmai
```

---

## 需要特別注意的差異

1. **gitlab-proxy / metricbeat**：這兩個需要先 build image 並推到 Container Registry
2. **Keycloak Redirect URI**：URL 會從 `localhost:PORT` 變為 K8S Ingress 的域名
3. **DATABASE_URL**：Outline 的 `?sslmode=disable` 已保留在 Secret 範本中
4. **Portainer**：K8S 環境中建議使用 K8S Dashboard 或 Lens 替代
