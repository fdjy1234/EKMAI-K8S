# EKMAI Kubernetes 遷移指南

本文件提供將 EKMAI 企業內網整合平台從 Docker Compose 遷移至 Kubernetes (K8S) 的完整規劃與技術指引。

---

## 目錄

1. [遷移可行性評估](#1-遷移可行性評估)
2. [架構對照：Docker Compose vs. Kubernetes](#2-架構對照docker-compose-vs-kubernetes)
3. [先決條件與環境準備](#3-先決條件與環境準備)
4. [遷移策略與階段規劃](#4-遷移策略與階段規劃)
5. [各服務遷移詳細指引](#5-各服務遷移詳細指引)
6. [共通基礎設施轉換](#6-共通基礎設施轉換)
7. [CI/CD 與 GitOps 整合](#7-cicd-與-gitops-整合)
8. [監控與可觀測性](#8-監控與可觀測性)
9. [安全性強化](#9-安全性強化)
10. [災難恢復與備份策略](#10-災難恢復與備份策略)
11. [成本與效益分析](#11-成本與效益分析)
12. [常見問題與排障](#12-常見問題與排障)

---

## 1. 遷移可行性評估

### 1.1 現有架構優勢（已具備的 K8S 友善基礎）

EKMAI 目前的設計已經具備多項 K8S 遷移友善特性：

| 現有設計 | K8S 對應 | 遷移難度 |
|---|---|:---:|
| 每個服務獨立 container image | → `Deployment` / `StatefulSet` | 🟢 低 |
| `ekmai-net` 統一 Docker Network | → K8S 內建 `Service Discovery` | 🟢 低 |
| `.env` 環境變數管理機密 | → `Secret` + `ConfigMap` | 🟢 低 |
| 全服務 Healthcheck 覆蓋 | → `livenessProbe` / `readinessProbe` | 🟢 低 |
| `restart: always` 策略 | → K8S 默認 `restartPolicy: Always` | 🟢 低 |
| Image Tag 版本鎖定 | → 可重現的部署 | 🟢 低 |
| 分 stack 的 Compose 結構 | → 每個 stack 對應一個 `Namespace` 或 Helm Release | 🟡 中 |
| 相對路徑掛載 `../infra/cert.pem` | → TLS `Secret` + cert-manager | 🟡 中 |
| `docker-compose.prod.yml` 覆蓋 | → Kustomize Overlay / Helm Values | 🟡 中 |

### 1.2 需要重新設計的部分

| 現有設計 | K8S 重新設計 | 遷移難度 |
|---|---|:---:|
| Docker named volumes | → `PersistentVolumeClaim (PVC)` + StorageClass | 🟡 中 |
| bind mount（`./config:/app/config`） | → `ConfigMap` volume mount | 🟡 中 |
| `ports:` 直接暴露宿主機 | → `Service` (ClusterIP/NodePort) + `Ingress` | 🟡 中 |
| build context（gitlab-proxy, metricbeat）| → 需預先建置並推送至 Container Registry | 🟠 高 |
| Docker socket 掛載（Portainer） | → 需要替代方案或 DaemonSet | 🟠 高 |
| HostPath 掛載（metricbeat） | → `DaemonSet` + hostPath 安全策略 | 🟠 高 |

### 1.3 決策矩陣：何時該遷移？

| 場景 | 建議 |
|---|---|
| 單機部署、5 人以下團隊 | **維持 Docker Compose** — 維運成本最低 |
| 需要高可用（HA） | **遷移 K8S** — 內建故障轉移與自動恢復 |
| 需要多節點部署 | **遷移 K8S** — 原生支援跨節點編排 |
| 需要自動擴縮容（HPA） | **遷移 K8S** — 內建 HorizontalPodAutoscaler |
| 已有 K8S 叢集可複用 | **遷移 K8S** — 整合既有基礎設施 |
| 需滿足企業合規要求 | **遷移 K8S** — 更完善的 RBAC 與審計能力 |

---

## 2. 架構對照：Docker Compose vs. Kubernetes

### 2.1 概念對照表

| Docker Compose | Kubernetes | 說明 |
|---|---|---|
| `services:` | `Deployment` / `StatefulSet` | 無狀態服務用 Deployment；有狀態（DB）用 StatefulSet |
| `image:` | `spec.containers[].image` | 完全相同 |
| `ports:` | `Service` (ClusterIP/NodePort/LoadBalancer) | K8S 不直接暴露 port，透過 Service 抽象 |
| `volumes:` (named) | `PersistentVolumeClaim` | 需要配合 StorageClass |
| `volumes:` (bind mount) | `ConfigMap` / `Secret` volume | 配置檔用 ConfigMap；機密用 Secret |
| `environment:` | `env:` / `envFrom:` | 可引用 ConfigMap 或 Secret |
| `.env` 檔案 | `Secret` / `ConfigMap` | 用 `kubectl create secret` 建立 |
| `depends_on:` | `initContainers` / Helm hook | K8S 原生無 depends_on；用 init container 等待 |
| `healthcheck:` | `livenessProbe` / `readinessProbe` / `startupProbe` | K8S 提供三種探測，更細緻 |
| `restart: always` | `restartPolicy: Always`（默認） | K8S Pod 默認就是 Always |
| `networks:` | K8S `Namespace` + `NetworkPolicy` | K8S 同 Namespace 內自動互通 |
| `docker-compose.prod.yml` | Kustomize overlay / Helm values | 環境差異化管理 |
| `docker network create` | `Namespace` | K8S 用 Namespace 隔離資源群 |

### 2.2 目標架構圖

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                           │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Namespace: ekmai-gateway                                     │    │
│  │  ┌─────────┐  ┌──────┐  ┌────────────┐  ┌─────────┐        │    │
│  │  │ APISIX  │  │ etcd │  │ Dashboard  │  │Prometheus│        │    │
│  │  │Ingress  │  │ (SS) │  │   (Dep)    │  │  (Dep)   │        │    │
│  │  │Ctrl(Dep)│  │      │  │            │  │          │        │    │
│  │  └────┬────┘  └──────┘  └────────────┘  └──────┬───┘        │    │
│  │       │                                         │            │    │
│  │       │              ┌──────────┐               │            │    │
│  │       └──────────────│ Grafana  │───────────────┘            │    │
│  │                      │  (Dep)   │                            │    │
│  │                      └──────────┘                            │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────┐  ┌──────────────────────────────┐     │
│  │ Namespace: ekmai-iam    │  │ Namespace: ekmai-collab      │     │
│  │  ┌──────────┐ ┌──────┐  │  │  ┌───────────┐ ┌──────────┐ │     │
│  │  │ Keycloak │ │ PG   │  │  │  │Mattermost │ │ PG       │ │     │
│  │  │  (Dep)   │ │ (SS) │  │  │  │  (Dep)    │ │ (SS)     │ │     │
│  │  └──────────┘ └──────┘  │  │  └───────────┘ └──────────┘ │     │
│  └─────────────────────────┘  └──────────────────────────────┘     │
│                                                                      │
│  ┌─────────────────────────┐  ┌──────────────────────────────┐     │
│  │ Namespace: ekmai-kb     │  │ Namespace: ekmai-observe     │     │
│  │  ┌────────┐ ┌────────┐  │  │  ┌───┐ ┌───────┐ ┌────────┐ │     │
│  │  │Wiki.js │ │Outline │  │  │  │ ES│ │Kibana │ │Logstash│ │     │
│  │  │ (Dep)  │ │ (Dep)  │  │  │  │(SS)│ │(Dep) │ │ (Dep)  │ │     │
│  │  └────────┘ └────────┘  │  │  └───┘ └───────┘ └────────┘ │     │
│  └─────────────────────────┘  └──────────────────────────────┘     │
│                                                                      │
│  (Dep) = Deployment  (SS) = StatefulSet                              │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 先決條件與環境準備

### 3.1 K8S 平台選擇

| 平台 | 適用場景 | 成本 |
|---|---|---|
| **Docker Desktop K8S** | 本機開發/PoC | 免費 |
| **Minikube** | 本機開發（Linux 最佳） | 免費 |
| **k3s** | 輕量級邊緣部署/內網 | 免費 |
| **Azure AKS** | 企業雲端 Azure 環境 | 按用量 |
| **AWS EKS** | 企業雲端 AWS 環境 | 按用量 |
| **Google GKE** | 企業雲端 GCP 環境 | 按用量 |
| **自建 kubeadm** | 完全自主控制的內網 | 硬體成本 |

> **建議**：EKMAI 主要面向企業內網，推薦使用 **k3s**（輕量）或 **自建 kubeadm** 叢集。若已有雲端訂閱，優先使用 Managed K8S（AKS/EKS/GKE）。

### 3.2 必要工具

```powershell
# kubectl — K8S 命令列工具
winget install Kubernetes.kubectl

# Helm — K8S 套件管理器
winget install Helm.Helm

# Kustomize — K8S 配置管理（kubectl 內建，但獨立版功能更完整）
winget install Kubernetes.kustomize

# Kompose — Docker Compose 轉 K8S 工具（選用）
# https://kompose.io/installation/
curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-windows-amd64.exe -o kompose.exe

# k9s — K8S 終端 UI 管理工具（選用但強烈推薦）
winget install Derailed.k9s
```

### 3.3 Container Registry

K8S 不支援 `build:` context（不像 Docker Compose 可以內建建置），需要先把自建 image 推到 Registry：

```powershell
# 自建的 image 需要推到 Registry
# 選項 1: Docker Hub
docker tag local-metricbeat:9.2.3 your-registry/ekmai-metricbeat:9.2.3
docker push your-registry/ekmai-metricbeat:9.2.3

# 選項 2: GitHub Container Registry (ghcr.io)
docker tag local-metricbeat:9.2.3 ghcr.io/fdjy1234/ekmai-metricbeat:9.2.3
docker push ghcr.io/fdjy1234/ekmai-metricbeat:9.2.3

# 選項 3: 自建 Harbor Registry（推薦企業內網）
docker tag local-metricbeat:9.2.3 harbor.it205.ski.ad/ekmai/metricbeat:9.2.3
docker push harbor.it205.ski.ad/ekmai/metricbeat:9.2.3
```

需要推送的自建 images：
- `Mattermost/gitlab-proxy` → 需要預先 `docker build` 並推送
- `elk/metricbeat` → 需要預先 `docker build` 並推送

### 3.4 Namespace 規劃

```powershell
# 建立 Namespace
kubectl create namespace ekmai-gateway    # APISIX / etcd / Prometheus / Grafana / Dashboard
kubectl create namespace ekmai-iam        # Keycloak / PostgreSQL
kubectl create namespace ekmai-collab     # Mattermost / PostgreSQL / GitLab Proxy
kubectl create namespace ekmai-kb         # Wiki.js / Outline / PostgreSQL / Redis
kubectl create namespace ekmai-observe    # Elasticsearch / Kibana / APM / Logstash / Metricbeat
```

---

## 4. 遷移策略與階段規劃

### 4.1 推薦策略：漸進式遷移（Strangler Fig Pattern）

不建議一次性遷移所有服務。推薦以下階段式方法：

```
Phase 1 (PoC)      →  先遷移一個服務驗證流程
Phase 2 (基礎設施)  →  遷移 APISIX + Keycloak（核心依賴）
Phase 3 (應用層)    →  遷移 Wiki.js / Outline / Mattermost
Phase 4 (可觀測性)  →  遷移 ELK Stack
Phase 5 (切換)      →  DNS 指向 K8S Ingress，下線 Docker Compose
```

### 4.2 階段一：PoC 驗證（預計 1-2 天）

**目標**：在本機 K8S 上跑起一個服務，驗證遷移流程。

**推薦 PoC 服務：Wiki.js**（原因：無外部依賴少、有官方 Helm Chart）

```powershell
# 啟用 Docker Desktop K8S 或安裝 minikube
# 然後部署 Wiki.js

helm repo add requarks https://charts.js.wiki
helm install wikijs requarks/wiki \
  --namespace ekmai-kb \
  --set postgresql.enabled=true \
  --set postgresql.auth.password=wikijsrocks \
  --set ingress.enabled=false
```

### 4.3 階段二：核心基礎設施（預計 3-5 天）

部署 APISIX + Keycloak，建立 K8S 上的流量入口與身分驗證基礎。

### 4.4 階段三：應用服務（預計 3-5 天）

逐一遷移 Mattermost、Wiki.js、Outline。

### 4.5 階段四：可觀測性（預計 2-3 天）

使用 ECK Operator 部署 Elasticsearch + Kibana + APM。

### 4.6 階段五：切換（預計 1-2 天）

更新 DNS 記錄，將流量切換到 K8S Ingress，保留 Docker Compose 作為 fallback。

---

## 5. 各服務遷移詳細指引

### 5.1 APISIX — API Gateway

#### 推薦方式：使用官方 Helm Chart

```powershell
# 新增 Helm Repo
helm repo add apisix https://charts.apiseven.com
helm repo update

# 安裝 APISIX（含 etcd + Dashboard）
helm install apisix apisix/apisix \
  --namespace ekmai-gateway \
  --set etcd.enabled=true \
  --set etcd.replicaCount=3 \
  --set dashboard.enabled=true \
  --set ingress-controller.enabled=true \
  --set apisix.ssl.enabled=true \
  -f apisix-values.yaml
```

#### apisix-values.yaml 範例

```yaml
# apisix-values.yaml
apisix:
  image:
    repository: apache/apisix
    tag: 3.14.1-debian
  replicaCount: 2

  ssl:
    enabled: true
    existingSecret: ekmai-tls-cert   # ← 企業 TLS 證書

  admin:
    credentials:
      admin: "edd1c9f034335f136f87ad84b625c8f1"    # ← 從 Secret 引用更佳
      viewer: "4054f7cf07e344346cd3f287985e76a2"
    allow:
      ipList:
        - "10.0.0.0/8"      # K8S Pod CIDR

  prometheus:
    enabled: true

etcd:
  replicaCount: 3            # 生產環境建議 3 節點
  persistence:
    enabled: true
    size: 8Gi

dashboard:
  enabled: true
  replicaCount: 1
  config:
    authentication:
      users:
        - username: admin
          password: admin    # ⚠️ 請更換

gateway:
  type: LoadBalancer         # 或 NodePort
  http:
    enabled: true
    servicePort: 80
  tls:
    enabled: true
    servicePort: 443

ingress-controller:
  enabled: true
  config:
    apisix:
      serviceNamespace: ekmai-gateway
```

#### 從 Docker Compose config.yaml 的轉換對照

| Compose config.yaml | Helm values.yaml |
|---|---|
| `apisix.node_listen: [9080, "9443 ssl"]` | `gateway.http.servicePort` / `gateway.tls.servicePort` |
| `deployment.admin.allow_admin` | `apisix.admin.allow.ipList` |
| `deployment.admin.admin_key` | `apisix.admin.credentials` |
| `deployment.etcd.host` | Helm 自動配置（同 Release 內的 etcd） |
| `plugin_attr.prometheus` | `apisix.prometheus.enabled` |

---

### 5.2 Keycloak — IAM / SSO

#### 方式 A：使用 Keycloak Operator（推薦）

```powershell
# 安裝 Keycloak Operator
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/refs/heads/main/kubernetes/kubernetes.yml \
  -n ekmai-iam
```

Keycloak CR（Custom Resource）範例：

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: ekmai-iam
spec:
  instances: 2                       # HA 雙節點
  hostname:
    hostname: keycloak.it205.ski.ad
  http:
    tlsSecret: ekmai-tls-cert       # TLS 證書 Secret
  db:
    vendor: postgres
    host: keycloak-db                # 指向 PostgreSQL Service
    port: 5432
    database: keycloak
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
```

#### 方式 B：使用 Bitnami Helm Chart

```powershell
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install keycloak bitnami/keycloak \
  --namespace ekmai-iam \
  --set auth.adminUser=admin \
  --set auth.adminPassword=${KEYCLOAK_ADMIN_PASSWORD} \
  --set postgresql.enabled=true \
  --set postgresql.auth.password=${KEYCLOAK_DB_PASSWORD} \
  --set replicaCount=2
```

#### Docker Compose → K8S 轉換對照

| Compose 設定 | K8S 對應 |
|---|---|
| `KEYCLOAK_ADMIN` / `PASSWORD` | → `Secret: keycloak-admin-secret` |
| `KC_DB_URL` | → Service DNS: `keycloak-db.ekmai-iam.svc.cluster.local:5432` |
| `KC_HOSTNAME: keycloak.it205.ski.ad` | → `Ingress` host rule |
| `KC_PROXY: edge` | → Ingress Controller 處理 TLS 終結 |
| `postgres_data` volume | → `PVC` with StorageClass |
| `keycloak_data` volume | → `PVC` (若需持久化 h2/file store) |
| `healthcheck` | → `readinessProbe` + `livenessProbe` |
| `ports: 5432:5432` | → **不暴露**，僅 ClusterIP 內部通訊 |

#### PostgreSQL StatefulSet 範例

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-db
  namespace: ekmai-iam
spec:
  serviceName: keycloak-db
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-db
  template:
    metadata:
      labels:
        app: keycloak-db
    spec:
      containers:
        - name: postgres
          image: postgres:17-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: keycloak
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: password
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "keycloak"]
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: db-data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: db-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak-db
  namespace: ekmai-iam
spec:
  clusterIP: None              # Headless Service for StatefulSet
  selector:
    app: keycloak-db
  ports:
    - port: 5432
```

---

### 5.3 Mattermost — 協作聊天

#### 推薦方式：Mattermost Operator

```powershell
# 安裝 Mattermost Operator
kubectl apply -n mattermost-operator \
  -f https://raw.githubusercontent.com/mattermost/mattermost-operator/master/docs/mattermost-operator/mattermost-operator.yaml
```

Mattermost CR 範例：

```yaml
apiVersion: installation.mattermost.com/v1beta1
kind: Mattermost
metadata:
  name: mattermost
  namespace: ekmai-collab
spec:
  size: 1000users              # 預設規模
  version: release-10
  ingress:
    enabled: true
    host: mattermost.it205.ski.ad
    tlsSecret: ekmai-tls-cert
  database:
    external:
      secret: mattermost-db-secret   # 包含 DB_CONNECTION_STRING
  fileStore:
    local:
      enabled: true
      storageSize: 50Gi
```

#### 轉換重點

- `gitlab-proxy` 需要先 build image 並推送到 Registry，然後用獨立的 `Deployment` 部署
- `MM_SERVICESETTINGS_SITEURL` 改為 K8S Ingress 的 URL

---

### 5.4 Wiki.js — 知識庫

#### 推薦方式：官方 Helm Chart

```powershell
helm repo add requarks https://charts.js.wiki
helm install wikijs requarks/wiki \
  --namespace ekmai-kb \
  --set postgresql.enabled=true \
  --set postgresql.auth.database=wiki \
  --set postgresql.auth.username=wiki \
  --set postgresql.auth.password=${POSTGRES_PASSWORD} \
  --set ingress.enabled=true \
  --set ingress.hostname=wikijs.it205.ski.ad \
  --set ingress.tls=true \
  --set ingress.tlsSecret=ekmai-tls-cert
```

#### 轉換重點

- `NODE_TLS_REJECT_UNAUTHORIZED: "0"` 可以在 K8S 中透過掛載企業根 CA 到信任儲存區來解決，而非關閉驗證
- `sideload` 目錄用 `ConfigMap` 或 `PVC` 取代
- `config.yml` 用 `ConfigMap` 掛載

---

### 5.5 Outline — 文件協作

#### 推薦方式：自訂 Deployment + Kustomize

Outline 目前沒有官方 Helm Chart，建議使用 Kustomize 管理：

```yaml
# outline/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: outline-app
  namespace: ekmai-kb
spec:
  replicas: 1
  selector:
    matchLabels:
      app: outline
  template:
    metadata:
      labels:
        app: outline
    spec:
      containers:
        - name: outline
          image: outlinewiki/outline:0.82.0
          ports:
            - containerPort: 3000
          envFrom:
            - secretRef:
                name: outline-secrets       # SECRET_KEY, UTILS_SECRET, OIDC_*
            - configMapRef:
                name: outline-config        # URL, FORCE_HTTPS, PGSSLMODE...
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: outline-db-secret
                  key: url
            - name: REDIS_URL
              value: redis://outline-redis:6379
          readinessProbe:
            httpGet:
              path: /_health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 15
          livenessProbe:
            httpGet:
              path: /_health
              port: 3000
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - name: data
              mountPath: /var/lib/outline/data
            - name: enterprise-ca
              mountPath: /etc/ssl/certs/enterprise-root-ca.crt
              subPath: ski-Root-CA.pem
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: outline-data
        - name: enterprise-ca
          secret:
            secretName: ekmai-root-ca
```

---

### 5.6 ELK Stack — 可觀測性

#### 推薦方式：ECK (Elastic Cloud on Kubernetes) Operator

ECK 是 Elastic 官方的 K8S Operator，可以管理 Elasticsearch、Kibana、APM Server、Logstash 等。

```powershell
# 安裝 ECK Operator
kubectl create -f https://download.elastic.co/downloads/eck/2.14.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.14.0/operator.yaml
```

#### Elasticsearch CR

```yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: ekmai-es
  namespace: ekmai-observe
spec:
  version: 9.2.3
  nodeSets:
    - name: default
      count: 3                    # 3 節點叢集
      config:
        node.store.allow_mmap: false
      volumeClaimTemplates:
        - metadata:
            name: elasticsearch-data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 50Gi
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources:
                requests:
                  memory: 2Gi
                  cpu: 1
                limits:
                  memory: 4Gi
                  cpu: 2
```

#### Kibana CR

```yaml
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata:
  name: ekmai-kibana
  namespace: ekmai-observe
spec:
  version: 9.2.3
  count: 1
  elasticsearchRef:
    name: ekmai-es
  http:
    tls:
      selfSignedCertificate:
        disabled: true           # APISIX 處理 TLS
```

#### APM Server CR

```yaml
apiVersion: apm.k8s.elastic.co/v1
kind: ApmServer
metadata:
  name: ekmai-apm
  namespace: ekmai-observe
spec:
  version: 9.2.3
  count: 1
  elasticsearchRef:
    name: ekmai-es
  kibanaRef:
    name: ekmai-kibana
```

#### Metricbeat — DaemonSet

```yaml
apiVersion: beat.k8s.elastic.co/v1beta1
kind: Beat
metadata:
  name: ekmai-metricbeat
  namespace: ekmai-observe
spec:
  type: metricbeat
  version: 9.2.3
  elasticsearchRef:
    name: ekmai-es
  kibanaRef:
    name: ekmai-kibana
  daemonSet:
    podTemplate:
      spec:
        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet
        containers:
          - name: metricbeat
            securityContext:
              runAsUser: 0
```

---

### 5.7 Portainer — 容器管理

#### K8S 替代方案

在 K8S 環境中，Portainer 的角色可以由以下工具取代：

| 工具 | 說明 |
|---|---|
| **Portainer CE (K8S 模式)** | Portainer 本身支援 K8S，但需要額外配置 |
| **Kubernetes Dashboard** | K8S 官方 Web UI |
| **Lens** | 桌面端 K8S IDE，功能最完整 |
| **k9s** | 終端端 K8S 管理工具 |
| **Rancher** | 企業級 K8S 多叢集管理平台 |

若仍希望使用 Portainer：

```powershell
helm repo add portainer https://portainer.github.io/k8s/
helm install portainer portainer/portainer \
  --namespace portainer --create-namespace \
  --set service.type=NodePort \
  --set tls.existingSecret=ekmai-tls-cert
```

---

## 6. 共通基礎設施轉換

### 6.1 TLS 證書管理

#### 選項 A：手動建立 Secret（適合企業內部 CA）

```powershell
# 將現有的企業證書匯入為 K8S Secret
kubectl create secret tls ekmai-tls-cert \
  --cert=infra/cert.pem \
  --key=infra/key.pem \
  --namespace ekmai-gateway

# 企業根 CA（讓服務信任內部簽發的證書）
kubectl create secret generic ekmai-root-ca \
  --from-file=ski-Root-CA.pem=infra/ski-Root-CA.pem \
  --namespace ekmai-gateway

# 複製到其他 Namespace
for ns in ekmai-iam ekmai-collab ekmai-kb ekmai-observe; do
  kubectl get secret ekmai-tls-cert -n ekmai-gateway -o yaml | \
    sed "s/namespace: ekmai-gateway/namespace: $ns/" | \
    kubectl apply -f -
done
```

#### 選項 B：cert-manager 自動化（推薦長期方案）

```powershell
# 安裝 cert-manager
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

```yaml
# 定義企業 CA Issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: enterprise-ca
spec:
  ca:
    secretName: enterprise-ca-key-pair   # 內含企業 CA 的 cert + key
```

### 6.2 機密管理

#### 建立 Secrets

```powershell
# Keycloak secrets
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=keycloak \
  --from-literal=password=keycloak_password \
  -n ekmai-iam

kubectl create secret generic keycloak-admin-secret \
  --from-literal=username=admin \
  --from-literal=password=admin_password \
  -n ekmai-iam

# Outline secrets
kubectl create secret generic outline-secrets \
  --from-literal=SECRET_KEY=9f3d7a... \
  --from-literal=UTILS_SECRET=3a7b9c... \
  --from-literal=OIDC_CLIENT_SECRET=Wo5Bg... \
  -n ekmai-kb

# ELK secrets
kubectl create secret generic elk-secrets \
  --from-literal=ELASTIC_PASSWORD=changeme \
  --from-literal=KIBANA_SYSTEM_PASSWORD=changeme_kibana \
  -n ekmai-observe
```

#### 進階方案：External Secrets Operator + Vault

```yaml
# 搭配 HashiCorp Vault
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: keycloak-db-secret
  namespace: ekmai-iam
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: keycloak-db-secret
  data:
    - secretKey: password
      remoteRef:
        key: secret/data/ekmai/keycloak
        property: db_password
```

### 6.3 Ingress 配置

使用 APISIX Ingress Controller 統一管理所有路由：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ekmai-ingress
  namespace: ekmai-gateway
  annotations:
    kubernetes.io/ingress.class: apisix
spec:
  tls:
    - hosts:
        - "*.it205.ski.ad"
      secretName: ekmai-tls-cert
  rules:
    - host: keycloak.it205.ski.ad
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080

    - host: mattermost.it205.ski.ad
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mattermost
                port:
                  number: 8065

    - host: wikijs.it205.ski.ad
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wikijs
                port:
                  number: 3000

    - host: outline.it205.ski.ad
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: outline-app
                port:
                  number: 3000
```

### 6.4 NetworkPolicy（網路隔離）

```yaml
# 限制 DB 只能被對應的應用存取
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-db-policy
  namespace: ekmai-iam
spec:
  podSelector:
    matchLabels:
      app: keycloak-db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: keycloak
      ports:
        - protocol: TCP
          port: 5432
```

---

## 7. CI/CD 與 GitOps 整合

### 7.1 推薦架構：ArgoCD + GitHub Actions

```
GitHub Actions (CI)          ArgoCD (CD)
┌──────────────────┐        ┌──────────────────┐
│ 1. Lint YAML     │        │ 1. Watch Git     │
│ 2. Build images  │ ────→  │ 2. Detect diff   │
│ 3. Push to GHCR  │        │ 3. Sync to K8S   │
│ 4. Update tag    │        │ 4. Health check  │
└──────────────────┘        └──────────────────┘
```

### 7.2 建議的 Git 目錄結構

```
EKMAI/
├─ docker-compose/           # 現有 Docker Compose（保留向後相容）
│  ├─ apisix/
│  ├─ keycloak/
│  └─ ...
├─ k8s/                      # K8S 部署配置
│  ├─ base/                  #   基礎配置
│  │  ├─ gateway/
│  │  │  ├─ kustomization.yaml
│  │  │  └─ ...
│  │  ├─ iam/
│  │  ├─ collab/
│  │  ├─ kb/
│  │  └─ observe/
│  ├─ overlays/              #   環境差異化
│  │  ├─ dev/
│  │  │  └─ kustomization.yaml
│  │  └─ prod/
│  │     └─ kustomization.yaml
│  └─ helm-values/           #   Helm Chart values
│     ├─ apisix-values.yaml
│     ├─ keycloak-values.yaml
│     └─ elk-values.yaml
├─ scripts/
│  ├─ start-all.ps1
│  ├─ stop-all.ps1
│  └─ k8s-deploy.ps1        # K8S 部署腳本
└─ README.md
```

### 7.3 ArgoCD 安裝與配置

```powershell
# 安裝 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 取得初始管理員密碼
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

```yaml
# ArgoCD Application 範例
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ekmai-gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/fdjy1234/EKMAI.git
    targetRevision: main
    path: k8s/overlays/prod/gateway
  destination:
    server: https://kubernetes.default.svc
    namespace: ekmai-gateway
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 8. 監控與可觀測性

### 8.1 K8S 原生監控增強

```powershell
# 安裝 Prometheus Stack（含 Grafana）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace ekmai-observe \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.scrapeInterval=15s
```

此 Stack 會自動整合：
- Prometheus（含 K8S 指標收集）
- Grafana（含預設 K8S Dashboard）
- Alertmanager（告警）
- node-exporter（節點指標）
- kube-state-metrics（K8S 物件狀態）

### 8.2 APISIX Metrics 整合

APISIX Helm Chart 會自動建立 `ServiceMonitor`，讓 Prometheus Operator 自動發現並抓取 APISIX metrics。

---

## 9. 安全性強化

### 9.1 RBAC

```yaml
# 為 EKMAI 管理員建立 ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ekmai-admin
rules:
  - apiGroups: ["", "apps", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["*"]
    namespaces: ["ekmai-gateway", "ekmai-iam", "ekmai-collab", "ekmai-kb", "ekmai-observe"]
```

### 9.2 Pod Security Standards

```yaml
# 限制 Pod 的安全上下文
apiVersion: v1
kind: Namespace
metadata:
  name: ekmai-kb
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 9.3 安全性檢查清單

- [ ] 所有 Secret 使用 K8S Secret（非 ConfigMap）
- [ ] DB Service 設為 ClusterIP（不暴露外部）
- [ ] 啟用 NetworkPolicy 限制跨 Namespace 通訊
- [ ] Image 使用特定版本 tag（非 `latest`）
- [ ] 容器以非 root 使用者執行（除 metricbeat 等必要例外）
- [ ] 啟用 PodDisruptionBudget（PDB）確保更新時不中斷
- [ ] 定期掃描 image 漏洞（Trivy / Snyk）

---

## 10. 災難恢復與備份策略

### 10.1 資料備份

```powershell
# 使用 Velero 進行叢集備份
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket=ekmai-backups

# 建立每日備份排程
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces ekmai-gateway,ekmai-iam,ekmai-collab,ekmai-kb,ekmai-observe
```

### 10.2 DB 備份（CronJob）

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-db-backup
  namespace: ekmai-iam
spec:
  schedule: "0 3 * * *"          # 每天凌晨 3 點
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: postgres:17-alpine
              command:
                - /bin/sh
                - -c
                - |
                  pg_dump -h keycloak-db -U keycloak keycloak | \
                    gzip > /backup/keycloak-$(date +%Y%m%d).sql.gz
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: password
              volumeMounts:
                - name: backup
                  mountPath: /backup
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: db-backup-pvc
          restartPolicy: OnFailure
```

---

## 11. 成本與效益分析

### 11.1 資源需求估算

| 服務 | CPU (request) | Memory (request) | Storage |
|---|---|---|---|
| APISIX × 2 | 500m × 2 | 512Mi × 2 | - |
| etcd × 3 | 500m × 3 | 1Gi × 3 | 8Gi × 3 |
| Keycloak × 2 | 500m × 2 | 1Gi × 2 | - |
| PostgreSQL (KC) | 250m | 512Mi | 5Gi |
| Mattermost | 500m | 1Gi | 10Gi |
| PostgreSQL (MM) | 250m | 512Mi | 5Gi |
| Wiki.js | 250m | 512Mi | 5Gi |
| Outline | 250m | 512Mi | 10Gi |
| Elasticsearch × 3 | 1000m × 3 | 2Gi × 3 | 50Gi × 3 |
| Kibana | 500m | 1Gi | - |
| **合計最小** | **~8 vCPU** | **~16 Gi** | **~220 Gi** |

### 11.2 建議硬體配置

| 規模 | 節點數 | 每節點規格 |
|---|---|---|
| 開發/測試 | 1 節點 | 8 vCPU / 16 GB / 256 GB SSD |
| 小型生產 | 3 節點 | 4 vCPU / 16 GB / 256 GB SSD |
| 標準生產 | 5 節點 | 8 vCPU / 32 GB / 512 GB SSD |

---

## 12. 常見問題與排障

### Q1: APISIX 路由在 K8S 上如何管理？

使用 APISIX Ingress Controller 後，可以用 K8S 原生的 `Ingress` 或 APISIX 的 CRD（`ApisixRoute`）來管理路由，不再需要透過 Admin API 手動設定。

### Q2: 現有的 OIDC 配置需要修改嗎？

需要更新 Keycloak 中各 Client 的 Redirect URI，因為服務 URL 會從 `localhost:PORT` 變為 K8S Ingress 的域名。

### Q3: 如何處理 Docker socket 掛載（Portainer / Metricbeat）？

- Portainer → 改用 K8S 模式或替換為 K8S Dashboard
- Metricbeat → 使用 ECK 的 `Beat` CRD，以 `DaemonSet` 方式部署

### Q4: 遷移期間兩邊能否並行運作？

可以。建議使用 DNS 權重路由（Weighted DNS）或 APISIX 的 traffic-split 插件，逐步將流量從 Docker Compose 切換到 K8S。

### Q5: 如果只有一台機器，K8S 有意義嗎？

可以使用 **k3s**（單節點 K8S），仍然能獲得 K8S 的聲明式管理、自動恢復、Secret 管理等能力，代價是比 Docker Compose 更高的學習曲線。

### Q6: 遷移回 Docker Compose 容易嗎？

可以隨時切回。建議保留原始的 `docker-compose.yml` 作為 fallback，直到 K8S 穩定運行至少 2 週。

---

## 附錄 A：Kompose 快速轉換參考

```powershell
# 使用 Kompose 做初步轉換（僅作參考，需手動調整）
cd d:\fdjy1234_github\EKMAI\apisix
kompose convert -f docker-compose.yml -o k8s/base/gateway/

cd d:\fdjy1234_github\EKMAI\keycloak
kompose convert -f docker-compose.yml -o k8s/base/iam/
```

> ⚠️ Kompose 的轉換結果通常只能作為起點，生產環境建議使用官方 Helm Chart 或手動撰寫 manifest。

---

## 附錄 B：參考資源

| 資源 | 連結 |
|---|---|
| APISIX Helm Chart | https://github.com/apache/apisix-helm-chart |
| APISIX Ingress Controller | https://apisix.apache.org/docs/ingress-controller/getting-started/ |
| Keycloak Operator | https://www.keycloak.org/operator/installation |
| ECK (Elastic Cloud on K8S) | https://www.elastic.co/guide/en/cloud-on-kubernetes/current |
| Mattermost Operator | https://github.com/mattermost/mattermost-operator |
| cert-manager | https://cert-manager.io/docs/ |
| ArgoCD | https://argo-cd.readthedocs.io/ |
| Velero (備份) | https://velero.io/docs/ |
| Kompose | https://kompose.io/ |
| k3s | https://k3s.io/ |
