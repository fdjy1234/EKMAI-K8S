# EKMAI-K8S — 企業內網整合平台 (Kubernetes 版)

本專案是 [EKMAI](https://github.com/fdjy1234/EKMAI) 的 Kubernetes 部署版本。原始專案使用 Docker Compose，本專案則使用 Helm Chart + Kustomize 將所有服務部署至 Kubernetes 叢集。

---

## 架構概覽

```
┌──────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                         │
│                                                               │
│  ekmai-gateway    ekmai-iam      ekmai-collab                │
│  ┌────────────┐  ┌───────────┐  ┌──────────────┐            │
│  │ APISIX     │  │ Keycloak  │  │ Mattermost   │            │
│  │ etcd       │  │ PostgreSQL│  │ PostgreSQL   │            │
│  │ Dashboard  │  └───────────┘  │ gitlab-proxy │            │
│  │ Prometheus │                  └──────────────┘            │
│  │ Grafana    │  ekmai-kb        ekmai-observe               │
│  └────────────┘  ┌───────────┐  ┌──────────────┐            │
│                   │ Wiki.js   │  │Elasticsearch │            │
│                   │ Outline   │  │ Kibana       │            │
│                   │ PostgreSQL│  │ APM Server   │            │
│                   │ Redis     │  │ Logstash     │            │
│                   └───────────┘  │ Metricbeat   │            │
│                                  └──────────────┘            │
└──────────────────────────────────────────────────────────────┘
```

| Namespace | 服務 | 部署方式 |
|---|---|---|
| `ekmai-gateway` | APISIX, etcd, Dashboard, Prometheus, Grafana | Helm Chart |
| `ekmai-iam` | Keycloak, PostgreSQL | Kustomize |
| `ekmai-collab` | Mattermost, PostgreSQL, gitlab-proxy | Kustomize |
| `ekmai-kb` | Wiki.js, Outline, PostgreSQL, Redis | Kustomize |
| `ekmai-observe` | Elasticsearch, Kibana, APM, Logstash, Metricbeat | ECK Operator |

---

## 先決條件

- Kubernetes 叢集（Docker Desktop K8S / minikube / k3s / AKS / EKS / GKE）
- `kubectl` (v1.28+)
- `helm` (v3.14+)
- `kustomize` (v5.0+，kubectl 內建)

```powershell
# Windows 安裝
winget install Kubernetes.kubectl
winget install Helm.Helm
winget install Derailed.k9s          # 選用但推薦
```

---

## 快速部署

### 1. 建立 Namespaces

```powershell
kubectl apply -f namespaces/namespaces.yaml
```

### 2. 建立 Secrets

```powershell
# 複製範本並填入實際值
cp secrets/secrets.example.yaml secrets/secrets.yaml
# 編輯 secrets/secrets.yaml ...
kubectl apply -f secrets/secrets.yaml

# TLS 證書
kubectl create secret tls ekmai-tls-cert --cert=cert.pem --key=key.pem -n ekmai-gateway
kubectl create secret generic ekmai-root-ca --from-file=ski-Root-CA.pem -n ekmai-gateway
```

### 3. 部署核心基礎設施

```powershell
# APISIX (Helm)
helm repo add apisix https://charts.apiseven.com
helm repo update
helm install apisix apisix/apisix -n ekmai-gateway -f helm-values/apisix-values.yaml

# Keycloak (Kustomize)
kubectl apply -k base/iam/
```

### 4. 部署應用服務

```powershell
kubectl apply -k base/collab/
kubectl apply -k base/kb/
```

### 5. 部署可觀測性

```powershell
# 安裝 ECK Operator（若尚未安裝）
kubectl create -f https://download.elastic.co/downloads/eck/2.14.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.14.0/operator.yaml

# 部署 ELK Stack
kubectl apply -k base/observe/
```

### 一鍵部署

```powershell
.\scripts\deploy-all.ps1
```

---

## 環境差異化

```powershell
# 開發環境（低資源、單 replica）
kubectl apply -k overlays/dev/

# 生產環境（HA、資源限制）
kubectl apply -k overlays/prod/
```

---

## 專案結構

```
EKMAI-K8S/
├── namespaces/              # Namespace 定義
├── base/                    # Kustomize base 配置
│   ├── gateway/             #   APISIX 額外配置
│   ├── iam/                 #   Keycloak + PostgreSQL
│   ├── collab/              #   Mattermost + gitlab-proxy
│   ├── kb/                  #   Wiki.js + Outline
│   └── observe/             #   ELK Stack (ECK CRs)
├── overlays/                # 環境差異化
│   ├── dev/
│   └── prod/
├── helm-values/             # Helm Chart values
├── secrets/                 # Secret 範本
├── scripts/                 # 部署腳本
└── docs/                    # 文件
```

---

## 與原始專案的關係

| | [EKMAI](https://github.com/fdjy1234/EKMAI) | EKMAI-K8S (本專案) |
|---|---|---|
| 部署方式 | Docker Compose | Kubernetes |
| 適用場景 | 單機 / 小團隊 | 多節點 / HA / 企業合規 |
| 網路 | `ekmai-net` bridge | K8S Service Discovery |
| 機密管理 | `.env` | K8S Secret |
| TLS | bind mount cert files | cert-manager / TLS Secret |

---

## 授權

本專案用於企業內部整合與驗證。若要對外發布，請先完成機密清理與安全性檢核。
