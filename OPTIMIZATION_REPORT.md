# EKMAI-K8S 系統優化工作報告

**日期**: 2026-03-31  
**執行者**: 系統架構師 (GitHub Copilot)  
**範圍**: 全面系統安全強化、架構修正、可靠性提升

---

## 執行摘要

本次優化針對 EKMAI-K8S 企業內網整合平台進行全面安全審計與架構優化，共修正 **30+ 項問題**，涵蓋安全漏洞、架構缺陷、可靠性缺失、運維工具不足等面向。

---

## 一、安全修正 (Critical / High)

### 1.1 Keycloak 開發模式 → 生產模式
- **風險等級**: 🔴 Critical
- **檔案**: `base/iam/keycloak.yaml`
- **問題**: Keycloak 使用 `start-dev` 啟動，禁用 HTTPS、允許未加密通訊
- **修正**: Base 改為 `start --optimized`，Dev overlay 中允許 `start-dev`

### 1.2 APISIX Admin API 對外開放
- **風險等級**: 🔴 Critical
- **檔案**: `helm-values/apisix-values.yaml`
- **問題**: Admin API 允許 `0.0.0.0/0` 存取，且使用預設 API Key
- **修正**: 限制為 K8s 內網 CIDR (`10.0.0.0/8`, `172.16.0.0/12`)，移除預設憑證

### 1.3 APISIX Dashboard 預設密碼
- **風險等級**: 🔴 Critical
- **檔案**: `helm-values/apisix-values.yaml`
- **問題**: Dashboard 使用 `admin/admin` 預設帳密
- **修正**: 改為佔位符，需手動替換

### 1.4 Grafana 預設密碼
- **風險等級**: 🟠 High
- **檔案**: `helm-values/prometheus-values.yaml`
- **問題**: Grafana `adminPassword: admin` 硬編碼
- **修正**: 改為使用 `existingSecret` 參考 K8s Secret

### 1.5 PostgreSQL 信任認證
- **風險等級**: 🔴 Critical
- **檔案**: `base/collab/postgres.yaml`
- **問題**: `POSTGRES_HOST_AUTH_METHOD: trust` 允許無密碼存取資料庫
- **修正**: 改為 `scram-sha-256`

### 1.6 TLS 驗證已停用
- **風險等級**: 🟠 High
- **檔案**: `base/collab/gitlab-proxy.yaml`
- **問題**: `KEYCLOAK_TLS_VERIFY: false` 容易遭受 MITM 攻擊
- **修正**: 改為 `true`

### 1.7 etcd RBAC 未啟用
- **風險等級**: 🟠 High
- **檔案**: `helm-values/apisix-values.yaml`
- **問題**: etcd RBAC `create: false, enabled: false`
- **修正**: 啟用 RBAC (`create: true, enabled: true`)

---

## 二、架構修正 (Critical)

### 2.1 Ingress 跨 Namespace 路由錯誤
- **風險等級**: 🔴 Critical — **服務無法路由**
- **檔案**: `base/gateway/ingress.yaml`
- **問題**: Ingress backend 使用 FQDN (如 `keycloak.ekmai-iam.svc.cluster.local`)，K8s Ingress 規範要求 backend service 必須在同一 namespace
- **修正**: 建立 ExternalName Service 作為跨 namespace 代理，Ingress 指向本地 ExternalName Service

### 2.2 Keycloak 資料遺失
- **風險等級**: 🟠 High
- **檔案**: `base/iam/keycloak.yaml`
- **問題**: Keycloak data 使用 `emptyDir`，Pod 重啟後資料遺失
- **修正**: 改為 PersistentVolumeClaim (1Gi)

---

## 三、Security Context 強化

### 3.1 新增 securityContext
- **檔案**: 所有 Deployment/StatefulSet
- **變更**:
  - Keycloak: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `drop: ALL`
  - gitlab-proxy: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `drop: ALL`
  - Mattermost: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `drop: ALL`
  - PostgreSQL (collab, iam): `allowPrivilegeEscalation: false`, `drop: ALL`

---

## 四、Health Probe 修正

| 元件 | 修正前 | 修正後 |
|------|--------|--------|
| Keycloak startup | `tcpSocket:8080` | `httpGet: /health/started` |
| Keycloak readiness | `tcpSocket:8080` | `httpGet: /health/ready` |
| Keycloak liveness | `tcpSocket:8080` | `httpGet: /health/live` |
| gitlab-proxy | ❌ 無任何 probe | ✅ TCP readiness + liveness |
| Outline DB (PostgreSQL) | ❌ 無 liveness | ✅ `pg_isready` liveness |
| Outline Redis | ❌ 無 liveness | ✅ `redis-cli ping` liveness |

---

## 五、網路安全強化

### 5.1 Default Deny NetworkPolicy
- **新增檔案**: `base/default-network-policies.yaml`
- **內容**: 所有 namespace 預設拒絕入站流量 + 限制出站（僅 DNS + EKMAI 內部）

### 5.2 Ingress NetworkPolicy
- **修改檔案**: `base/iam/networkpolicy.yaml`, `base/collab/networkpolicy.yaml`, `base/kb/networkpolicy.yaml`
- **內容**: 允許 Gateway namespace 存取各應用服務

---

## 六、可靠性提升

### 6.1 PodDisruptionBudgets
- **新增檔案**: `base/pod-disruption-budgets.yaml`
- **涵蓋**: Keycloak, Mattermost, Outline, Wiki.js (`minAvailable: 1`)

### 6.2 LimitRanges
- **新增檔案**: `base/limitranges.yaml`
- **涵蓋**: 所有 5 個 namespace，設定預設 CPU/Memory 限制

### 6.3 Resource Limits
- **Logstash**: 新增 `requests: 250m/512Mi`, `limits: 1000m/1Gi`

### 6.4 Prod Overlay 強化
- **Keycloak**: 新增 `topologySpreadConstraints` 確保跨節點分散
- **Elasticsearch**: 生產環境儲存提升至 20Gi
- **PostgreSQL**: Keycloak/Mattermost DB 儲存提升至 10Gi

### 6.5 Dev Overlay 調整
- Dev 環境明確使用 `start-dev` 模式

---

## 七、運維工具新增

### 7.1 健康檢查腳本
- **新增檔案**: `scripts/healthcheck.ps1`
- **功能**: Pod 狀態、PVC 綁定、Service 端點、資源用量、Warning 事件、NetworkPolicy 統計

### 7.2 資料庫備份腳本
- **新增檔案**: `scripts/backup-databases.ps1`
- **功能**: 備份所有 PostgreSQL (Keycloak, Mattermost, Wiki.js, Outline)

### 7.3 Port Forward 腳本升級
- **修改檔案**: `scripts/k8s-port-forward.ps1`
- **變更**: 從 3 個服務擴展到 9 個服務 (APISIX, Keycloak, Mattermost, Wiki.js, Outline, Kibana, Grafana, K8S Dashboard)

---

## 八、部署腳本修正

### 8.1 deploy-all.ps1
- ECK CRD 安裝改為 `kubectl apply --server-side`（冪等操作）
- 新增 LimitRanges、Default NetworkPolicy、PDB 部署步驟
- 步驟從 9 步增加到 11 步 + overlay + PDB

### 8.2 teardown-all.ps1
- 新增 PDB、Default NetworkPolicy、LimitRange 清理步驟

### 8.3 .gitignore 強化
- 新增 `secrets/secrets.yaml`、`backups/`、證書檔案排除

---

## 九、Observe Namespace 修正

- `base/observe/kustomization.yaml`: 新增遺漏的 `namespace: ekmai-observe`

---

## 十、Secrets 範本更新

- `secrets/secrets.example.yaml`: 新增 Grafana admin secret (`grafana-admin-secret`)

---

## 變更清單

| 操作 | 檔案 |
|------|------|
| 修改 | `base/iam/keycloak.yaml` |
| 修改 | `base/iam/postgres.yaml` |
| 修改 | `base/iam/networkpolicy.yaml` |
| 修改 | `base/collab/gitlab-proxy.yaml` |
| 修改 | `base/collab/mattermost.yaml` |
| 修改 | `base/collab/postgres.yaml` |
| 修改 | `base/collab/networkpolicy.yaml` |
| 修改 | `base/kb/outline.yaml` |
| 修改 | `base/kb/networkpolicy.yaml` |
| 修改 | `base/gateway/ingress.yaml` |
| 修改 | `base/observe/logstash.yaml` |
| 修改 | `base/observe/kustomization.yaml` |
| 新增 | `base/pod-disruption-budgets.yaml` |
| 新增 | `base/limitranges.yaml` |
| 新增 | `base/default-network-policies.yaml` |
| 修改 | `helm-values/apisix-values.yaml` |
| 修改 | `helm-values/prometheus-values.yaml` |
| 修改 | `overlays/dev/kustomization.yaml` |
| 修改 | `overlays/prod/kustomization.yaml` |
| 修改 | `secrets/secrets.example.yaml` |
| 修改 | `scripts/deploy-all.ps1` |
| 修改 | `scripts/teardown-all.ps1` |
| 修改 | `scripts/k8s-port-forward.ps1` |
| 新增 | `scripts/healthcheck.ps1` |
| 新增 | `scripts/backup-databases.ps1` |
| 修改 | `.gitignore` |

---

## 後續建議

1. **cert-manager 整合**: 自動管理 TLS 證書更新，取代手動 kubectl create secret tls
2. **Sealed Secrets / External Secrets**: 將 Secret 管理納入 GitOps 工作流程
3. **HorizontalPodAutoscaler**: 根據 CPU/Memory 自動擴縮 Keycloak、Mattermost
4. **Velero 備份**: 整合 Velero 做叢集層級備份恢復
5. **Image Tag Pinning**: 將 `latest` tag 改為特定版本號
6. **CI/CD Pipeline**: 加入 kustomize build 驗證、kubeval/kubeconform lint
7. **Pod Security Standards**: 啟用 K8s Admission Controller 的 Pod Security Standards
