# Foundry VTT Kubernetes Operator
## Design Document
*v0.2 · Draft — Round 1 complete*
*Last updated: 2026-03-23*

---

## Decisions log

| Decision | Chosen | Rationale |
|---|---|---|
| Gateway API only — no Ingress fallback | Gateway API exclusively | Eliminates dual code path; enables ReferenceGrant, BackendTLSPolicy; Ingress is legacy |
| Framework | kubebuilder / controller-runtime | operator-sdk is layered on top of kubebuilder; no benefit to the extra abstraction for a pure-Go operator |
| TLS termination point | At the Gateway, not inside the Pod | Removes certificate-handling responsibility from Caddy; recommended model for Envoy Gateway and Cilium |
| PVC lifecycle on CR deletion | Orphan the PVC | Prevents accidental world loss; PVC can be manually deleted when no longer needed |
| Update strategy | `Recreate` (not `RollingUpdate`) | Single-replica + RWO PVC: a rolling update would hang waiting for the new Pod to acquire the PVC; Recreate is the correct and honest strategy |
| Caddy admin bind address | `127.0.0.1:2019` (localhost only) | Security hardening; the admin API is not a public surface |

---

## Open questions

| # | Topic | Notes | Blocking? |
|---|---|---|---|
| 1 | **Backup approach: rclone sync vs. volume snapshot** | RWO PVC + separate CronJob Pod = scheduling hazard on multi-node clusters (see section 9.2). Three options: (a) node affinity on CronJob, (b) volume snapshot (VolumeSnapshot API), (c) backup sidecar in the Foundry Pod. Decision needed before implementation. | **Yes — blocks section 9** |
| 2 | **`/setup` and oauth2-proxy** | The Foundry `/setup` route is how admins enter their licence key and configure the instance on first launch. oauth2-proxy sits in front of everything. Does `/setup` bypass auth? If yes, how is it secured against unauthorized access? If no, the admin must already be authenticated to complete setup — which may not be possible on first install. | **Yes — blocks section 8.4** |
| 3 | **Backup data consistency** | Foundry VTT v11+ uses SQLite for world databases. rclone sync on a live data directory may capture a partial write or an incomplete WAL file, producing a corrupt backup. Options: (a) quiesce Foundry before backup (pause → backup → unpause), (b) use SQLite online backup API, (c) document as crash-consistent and accept the risk. | Yes — blocks section 9.2 |
| 4 | **Paused instance UX** | When `spec.paused: true`, the Deployment scales to 0 but the HTTPRoute and Service remain. Requests hit the Service, find no endpoints, and the Gateway returns a 502/503. Should the operator inject a static "paused" page (e.g. a minimal nginx Pod)? Or is a 502 acceptable? | No — can defer to v1.1 |
| 5 | **CRD storage version at initial release** | Section 5.1 shows a version progression `v1alpha1 → v1beta1 → v1`. What is served and stored at initial release? Conversion webhooks must be designed before multiple versions are served simultaneously. | No — only matters at v1beta1 promotion |
| 6 | **Foundry licence validation in status** | Should the operator surface licence expiry in `status.conditions`? Requires polling `/api/status`. | No |
| 7 | **Multi-world PVC strategy** | Single PVC with sub-directories vs. separate PVCs per world. | No |
| 8 | **Backup compression** | rclone `--compress` flag for large asset collections. | No |
| 9 | **Metrics & alerting** | Prometheus metrics: backup age, certificate TTL, pod restart count. ServiceMonitor CRD for Prometheus Operator integration. | No |
| 10 | **Version pinning & auto-update** | Should the operator auto-update the Foundry image tag or require an explicit spec change? | No |
| 11 | **Restore workflow** | Operator currently only writes backups. A status-driven restore (`spec.storage.backup.restoreFrom`) would complete the data recovery story. | No — v1.1 |
| 12 | **Multi-tenant Gateway documentation** | Document the exact ReferenceGrant pattern when many `FoundryServer` instances share one Gateway across namespaces. | No |

---

## 1. Purpose, Scope & Users

### 1.1 Purpose

This document describes the design of a Kubernetes operator that manages the full lifecycle of Foundry Virtual Tabletop (Foundry VTT) server instances. The operator introduces the `FoundryServer` Custom Resource Definition (CRD) and a controller that reconciles the desired state expressed in that resource against the live cluster state.

### 1.2 User personas

**Cluster admin** — Installs and upgrades the operator. Manages cluster infrastructure: Gateway API CRDs, cert-manager, StorageClasses, OIDC providers. Responsible for operator RBAC and namespace provisioning. Does not manage individual Foundry instances.

**Instance owner (game master)** — Creates and manages `FoundryServer` resources in their namespace. Wants to provision a Foundry instance, configure backups, pause/resume the server around game sessions, and never think about Kubernetes details beyond applying a manifest.

The operator is designed primarily for the instance owner. The cluster admin's interaction is limited to the initial operator install and infrastructure prerequisites.

### 1.3 Goals

| Goal | Success condition |
|---|---|
| Declarative, Kubernetes-native API for Foundry VTT instances | A `FoundryServer` CR reaches `status.phase = Running` within 5 minutes of creation on a cluster with all prerequisites healthy |
| All ancillary infrastructure managed automatically | An instance owner can provision a fully working instance by applying a single manifest with ≤5 required fields |
| Reliable backups to S3-compatible storage | Backup CronJobs complete successfully; `status.lastBackupStatus = Succeeded` reflects actual job outcome; backup files are recoverable |
| Secure external access via Caddy + oauth2-proxy | All traffic passes through oauth2-proxy; the Foundry admin interface is not publicly accessible without authentication |

### 1.4 Non-goals (v1)

- Multi-node / distributed Foundry deployments
- Automatic Foundry VTT licence procurement
- In-cluster world import/export tooling beyond backup schedules
- Support for `networking.k8s.io/v1` Ingress — the operator targets Gateway API exclusively and will not add Ingress support
- Restore workflow (acknowledged gap — targeted for v1.1; see open question 11)

### 1.5 User stories

**Instance owner:**
- As an instance owner, I want to apply one manifest and have a running Foundry instance with TLS and SSO, so that I don't need to configure Ingress, cert-manager, or oauth2-proxy manually.
- As an instance owner, I want to pause my Foundry server when not in use, so that I'm not paying for compute between game sessions.
- As an instance owner, I want automated nightly backups of my world data to S3, so that I can recover from accidental deletion or data corruption.
- As an instance owner, I want to see the health of my instance (TLS, backup, auth) at a glance via `kubectl get foundryserver`, so that I know immediately if something needs attention.
- As an instance owner, I want to use a custom-built Foundry image from a private registry, so that I can control exactly which version and build is running.

**Cluster admin:**
- As a cluster admin, I want the operator to refuse to start if required dependencies are missing, so that I get a clear error rather than partially-broken instances.
- As a cluster admin, I want all operator RBAC permissions to be generated from code annotations, so that the ClusterRole stays in sync with what the controller actually uses.

---

## 2. Cluster Prerequisites

The operator targets modern clusters and depends on APIs that graduated to GA in Kubernetes 1.28. The following components must be present and healthy before the operator is installed. The operator performs preflight checks at startup and refuses to start if any required API group is unavailable (see section 3).

### 2.1 Required Kubernetes version

| Requirement | Minimum version / notes |
|---|---|
| Kubernetes | 1.28+ — Gateway API v1 (HTTPRoute, Gateway, GatewayClass) graduated to GA in this release |
| Gateway API CRDs | v1.2.0+ — must be installed cluster-wide before the operator is deployed |
| cert-manager | v1.15.0+ — required for Gateway API integration via `spec.issuerRef` on Certificate resources |

### 2.2 Required cluster components

| Component | Recommended implementation | Notes |
|---|---|---|
| Gateway API implementation | Envoy Gateway or Cilium | Any conformant implementation works; see section 8 for TLS mode considerations |
| cert-manager | cert-manager v1.15+ | Must have a ClusterIssuer or Issuer available in the target namespace |
| StorageClass | Cluster default | Any RWO-capable StorageClass; configurable per FoundryServer |
| OIDC / OAuth2 provider | Keycloak, Auth0, Dex, etc. | Required only if `spec.auth.enabled` is true (the default) |

> **Note:** The operator does not install cert-manager or the Gateway API CRDs itself. These are infrastructure-layer dependencies that should be managed by cluster administrators, not by an application operator.

---

## 3. Operator Preflight Checks

On startup, before the controller manager begins its reconciliation loops, the operator runs a series of preflight checks against the API server. If any check fails, the operator logs a clear human-readable error and exits with a non-zero code rather than starting in a degraded state.

### 3.1 Required API group checks

The operator calls the API server discovery endpoint and asserts the presence of the following API groups and resources:

| API group | Resources checked | Failure message |
|---|---|---|
| `gateway.networking.k8s.io/v1` | gateways, httproutes | Gateway API v1 CRDs not found. Install the Gateway API CRDs (v1.2.0+) before deploying this operator. |
| `gateway.networking.k8s.io/v1beta1` | referencegrants | ReferenceGrant CRD not found. Install the Gateway API CRDs (v1.2.0+) before deploying this operator. |
| `cert-manager.io/v1` | certificates, issuers, clusterissuers | cert-manager CRDs not found. Install cert-manager (v1.15.0+) before deploying this operator. |

### 3.2 Liveness of dependencies

In addition to API group presence, the operator checks that the core dependencies are operational:

- **cert-manager webhook:** The operator performs a dry-run create of a Certificate resource and expects a valid admission response. A timeout or error here indicates cert-manager's webhook is not ready.
- **Gateway API implementation:** The operator lists GatewayClass resources and emits a warning (non-fatal) if none are found. It does not block startup on this check, since a GatewayClass may be added after the operator is installed.
- **Issuer availability:** The operator does not check for a valid Issuer/ClusterIssuer at startup (it cannot know which namespace or issuer a future CR will reference). However, the reconciler explicitly checks for an accessible Issuer before creating a Certificate and surfaces a descriptive `CertificateReady=False` condition if none is found, rather than delegating the error entirely to cert-manager.

> **Note:** Preflight checks run only at operator startup, not during each reconciliation loop. If a dependency is removed after the operator is running, the relevant FoundryServer resources will enter a `Degraded` state with a descriptive condition message.

### 3.3 CEL validation on the CRD

In addition to runtime preflight checks, the `FoundryServer` CRD uses Kubernetes Common Expression Language (CEL) validation rules to catch invalid specs at admission time — before they reach the reconciler.

```yaml
# Excerpt from CRD validation rules
x-kubernetes-validations:

  # gatewayRef is required — there is no Ingress fallback
  - rule: "has(self.ingress.gateway.gatewayRef)"
    message: "spec.ingress.gateway.gatewayRef is required"

  # TLS issuerRef required when TLS is enabled
  - rule: "!self.ingress.tls.enabled || has(self.ingress.tls.issuerRef)"
    message: "spec.ingress.tls.issuerRef is required when tls.enabled is true"

  # Backup credentialsRef required when backup is enabled
  - rule: "!self.storage.backup.enabled || has(self.storage.backup.credentialsRef)"
    message: "spec.storage.backup.credentialsRef is required when backup.enabled is true"

  # auth clientID required when auth is enabled
  - rule: "!self.auth.enabled || self.auth.clientID != ''"
    message: "spec.auth.clientID is required when auth.enabled is true"

  # hostname must be a valid DNS name
  - rule: "self.ingress.hostname.matches('^[a-z0-9]([a-z0-9\\-\\.]*[a-z0-9])?$')"
    message: "spec.ingress.hostname must be a valid DNS hostname"

  # updateStrategy must be Recreate for single-replica RWO workloads
  - rule: "self.updateStrategy == 'Recreate'"
    message: "spec.updateStrategy must be Recreate; RollingUpdate is not supported for single-replica RWO workloads"
```

---

## 4. Architecture Overview

The operator follows the standard controller-runtime pattern. A single Deployment runs the manager process with **leader election enabled**, watching `FoundryServer` resources cluster-wide (or within a configurable set of namespaces) and driving reconciliation. Leader election is required: if the operator Deployment is scaled beyond 1 replica for availability, without it multiple reconcilers would conflict on the same resources.

### 4.1 Pod topology

Each `FoundryServer` instance maps to a single Kubernetes Pod (wrapped in a Deployment with replica count 1). The Pod contains three containers:

| Container | Default image | Role |
|---|---|---|
| `foundry` | `felddy/foundryvtt:12.331` *(pin to a version tag — do not use `release` in production)* | Main Foundry VTT process |
| `caddy` | `caddy:2.8` *(pin to a version tag — do not use `alpine` floating tag in production)* | Reverse proxy — header manipulation, rate-limiting |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0` *(pin to a version tag)* | SSO/OAuth2 enforcement in front of Caddy |

> **Image tagging:** All three default images must be pinned to a specific version tag, not a floating tag like `latest` or `release`. Floating tags can silently change runtime behaviour on node image pulls. For production deployments, digest pinning (`@sha256:...`) is recommended. See section 4.5.

> **Note:** The oauth2-proxy listens on the external port (4180). It forwards authenticated requests to Caddy (127.0.0.1:2019), which in turn proxies to Foundry (127.0.0.1:30000). All three containers share the Pod network namespace.

### 4.2 Component diagram

Traffic flow for an inbound HTTPS request (Gateway API terminates TLS):

```
  Internet
     │  HTTPS :443
     ▼
  Gateway (Envoy Gateway / Cilium)  ◄──  cert-manager Certificate
     │  HTTP (TLS terminated at Gateway)
     ▼
  [oauth2-proxy :4180]  ──── OIDC redirect ────►  IdP (Keycloak / Auth0 / etc.)
     │  authenticated, plain HTTP
     ▼
  [caddy :2019]  (headers, rate-limiting, upstream health)
     │  http://localhost:30000
     ▼
  [foundryvtt :30000]
```

### 4.3 Operator component diagram

```
  ┌─────────────────────────────────────────────────────┐
  │  foundry-operator (Deployment, leader-elected)      │
  │                                                     │
  │  ┌──────────────────────┐  ┌──────────────────────┐ │
  │  │  FoundryServer       │  │  Backup Controller   │ │
  │  │  Reconciler          │  │  (CronJob manager)   │ │
  │  └──────────┬───────────┘  └──────────┬───────────┘ │
  └─────────────│────────────────────────│─────────────┘
                │ manages                 │ manages
     ┌──────────▼──────────┐   ┌──────────▼──────────┐
     │  Deployment / Pod   │   │  CronJob (rclone)   │
     │  Service            │   │  Secret (S3 creds)  │
     │  HTTPRoute          │   └─────────────────────┘
     │  Certificate        │
     │  ConfigMap (caddy)  │
     │  ConfigMap (oauth2) │
     │  PVC                │
     └─────────────────────┘
```

### 4.4 Implementation framework — kubebuilder

The operator is implemented in Go using the kubebuilder framework (`sigs.k8s.io/controller-runtime`). kubebuilder is the reference framework for Kubernetes operators maintained by the sig-api-machinery community. It was chosen over operator-sdk because operator-sdk is itself layered on top of kubebuilder, and the additional abstraction is not needed for a pure-Go operator.

Key kubebuilder capabilities used by this operator:

- **CRD generation:** Go struct annotations (`// +kubebuilder:validation:...`) drive automatic generation of the `FoundryServer` CRD YAML, including CEL validation rules and OpenAPI schema.
- **RBAC generation:** Controller method annotations (`// +kubebuilder:rbac:...`) generate the ClusterRole manifest, keeping permissions in sync with the code.
- **Webhook scaffolding:** kubebuilder generates the admission webhook boilerplate for the defaulting and validating webhooks.
- **envtest integration:** Controller tests run against a real API server binary via the envtest package, giving high-fidelity integration tests without a full cluster.
- **controller-runtime:** The underlying library provides the reconciler interface, event queuing, leader election, metrics endpoint, and health probes.

### 4.5 Image management & custom registries

All three sidecar image fields accept any valid OCI image reference, including digest-pinned references and images hosted on private registries.

| Spec field | Default image | Note |
|---|---|---|
| `spec.foundry.image` | `felddy/foundryvtt:12.331` | Pin to a specific version tag |
| `spec.caddy.image` | `caddy:2.8` | Pin to a specific version tag |
| `spec.auth.image` | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0` | Pin to a specific version tag |

For production deployments, digest pinning eliminates tag mutability risk:

```yaml
spec:
  foundry:
    image: registry.example.com/foundry/foundryvtt@sha256:abc123...
```

> **Note:** Building custom images is treated as a separate concern. The key requirement for the Foundry image is that it must set the `FOUNDRY_VERSION` label so the operator can populate `status.foundryVersion`.

---

## 5. FoundryServer Custom Resource Definition

The `FoundryServer` CRD is the primary API surface of the operator. Every field in the spec is optional unless marked required; the operator applies sensible defaults to unset fields.

### 5.1 Group, version, and kind

| Property | Value |
|---|---|
| API Group | `foundry.vtt.io` |
| Version | `v1alpha1` → `v1beta1` → `v1` |
| Kind | `FoundryServer` |
| Plural | `foundryservers` |
| Short name | `fvtt` |
| Scope | Namespaced |

### 5.2 Minimal manifest (getting started)

The smallest working manifest. All omitted fields use operator defaults.

```yaml
apiVersion: foundry.vtt.io/v1alpha1
kind: FoundryServer
metadata:
  name: my-campaign
  namespace: foundry
spec:
  ingress:
    hostname: my-campaign.vtt.example.com   # REQUIRED
    gateway:
      gatewayRef:
        name: prod-gateway                  # REQUIRED
        namespace: gateway-system
    tls:
      issuerRef:
        name: letsencrypt-prod             # REQUIRED if tls.enabled (default: true)
        kind: ClusterIssuer
  auth:
    clientID: foundry-client               # REQUIRED if auth.enabled (default: true)
    clientSecretRef:
      name: foundry-oauth-secret
      key: clientSecret
    cookieSecretRef:
      name: foundry-oauth-secret
      key: cookieSecret
    issuerURL: https://auth.example.com/realms/vtt
```

### 5.3 Full manifest with all fields

```yaml
apiVersion: foundry.vtt.io/v1alpha1
kind: FoundryServer
metadata:
  name: my-campaign          # REQUIRED — unique name in namespace
  namespace: foundry
  labels:
    campaign: curse-of-strahd
spec:

  # ── Image ──────────────────────────────────────────────────────
  foundry:
    image: felddy/foundryvtt:12.331        # pin to a version tag
    licenseKey:
      secretRef:
        name: foundry-license           # optional
        key: licenseKey
    adminPassword:
      secretRef:
        name: foundry-license
        key: adminPassword
    env: []
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: '2'
        memory: 2Gi

  # ── Storage ─────────────────────────────────────────────────────
  storage:
    data:
      storageClassName: standard
      size: 10Gi
      accessMode: ReadWriteOnce
      existingClaim: ''
      # Set to Delete to have the PVC removed when the FoundryServer is deleted.
      # Default is Retain (PVC is orphaned) to prevent accidental world loss.
      reclaimPolicy: Retain

    backup:
      enabled: false
      schedule: '0 3 * * *'
      # Number of daily backups to retain. Implemented as --max-age <retention>d
      # passed to rclone. Note: if the schedule is more frequent than daily,
      # adjust retention accordingly — e.g. hourly schedule with retention: 168
      # keeps one week of hourly backups.
      retention: 7
      destination: s3://my-bucket/foundry/my-campaign/
      credentialsRef:
        name: foundry-s3-creds             # REQUIRED if enabled
      rcloneFlags: '--s3-acl private'

  # ── Networking ──────────────────────────────────────────────────
  ingress:
    hostname: my-campaign.vtt.example.com  # REQUIRED
    gateway:
      gatewayRef:
        name: prod-gateway                 # REQUIRED
        namespace: gateway-system
        group: gateway.networking.k8s.io
        kind: Gateway
      listenerName: https
    tls:
      enabled: true
      issuerRef:
        name: letsencrypt-prod             # REQUIRED if tls.enabled
        kind: ClusterIssuer
        group: cert-manager.io
      secretName: ''

  # ── Caddy reverse proxy ──────────────────────────────────────────
  caddy:
    image: caddy:2.8                       # pin to a version tag
    extraConfig: ''
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits:   { cpu: 200m, memory: 128Mi }

  # ── OAuth2 / SSO proxy ───────────────────────────────────────────
  auth:
    enabled: true
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0  # pin to a version tag
    provider: oidc
    issuerURL: https://auth.example.com/realms/vtt
    clientID: foundry-client               # REQUIRED if auth.enabled
    clientSecretRef:
      name: foundry-oauth-secret           # REQUIRED if auth.enabled
      key: clientSecret
    cookieSecretRef:
      name: foundry-oauth-secret
      key: cookieSecret
    emailDomains:
      - example.com
    skipAuthPaths:
      - '^/socket\.io'
      - '^/modules'
      - '^/systems'
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits:   { cpu: 200m, memory: 128Mi }

  # ── Scheduling / operations ──────────────────────────────────────
  replicas: 1                              # always 1 for Foundry VTT
  paused: false
  # Must be Recreate. RollingUpdate is not supported: a rolling update
  # cannot start the new Pod until the old Pod releases the RWO PVC,
  # causing the rollout to hang until Kubernetes times out the old Pod.
  updateStrategy: Recreate
  nodeSelector: {}
  tolerations: []
  affinity: {}
  priorityClassName: ''
```

### 5.4 Field reference

| Spec group | Operator action | Kubernetes resources created |
|---|---|---|
| `spec.foundry` | Creates / updates main container spec | Deployment |
| `spec.storage.data` | Provisions world/asset storage | PersistentVolumeClaim |
| `spec.storage.backup` | Schedules S3 sync jobs | CronJob, Secret (rclone env) |
| `spec.ingress.gateway` | Declares HTTP routing | HTTPRoute, ReferenceGrant |
| `spec.ingress.tls` | Issues and rotates TLS certificate | Certificate (cert-manager) |
| `spec.caddy` | Generates Caddyfile, injects sidecar | ConfigMap, Deployment (sidecar) |
| `spec.auth` | Generates oauth2-proxy config, injects sidecar | ConfigMap, Secret, Deployment (sidecar) |

---

## 6. Status & Conditions

The operator writes back to `status.conditions` following the Kubernetes standard condition API.

### 6.1 Status fields

| Field | Description |
|---|---|
| `status.phase` | `Pending` \| `Provisioning` \| `Running` \| `Degraded` \| `Paused` \| `Failed` |
| `status.url` | Public URL derived from `spec.ingress.hostname` once ready |
| `status.foundryVersion` | Detected Foundry VTT version from container labels |
| `status.storageReady` | `true` when the PVC is Bound |
| `status.certificateReady` | `true` when the cert-manager Certificate reaches `Ready=True` |
| `status.lastBackupTime` | RFC3339 timestamp of most recent successful S3 backup |
| `status.lastBackupStatus` | `Succeeded` \| `Failed` |
| `status.observedGeneration` | Tracks spec changes that have been reconciled |
| `status.conditions[]` | Standard Kubernetes conditions array (see below) |

### 6.2 Conditions

| Condition type | Meaning when True | Meaning when False / Unknown |
|---|---|---|
| `Available` | Deployment has ≥1 ready replica | Pod is not yet running or has crashed |
| `Progressing` | Rollout is in progress | No rollout underway |
| `StorageReady` | PVC is Bound | PVC is Pending or lost |
| `CertificateReady` | TLS certificate issued and not expiring soon | Certificate not yet issued or renewal failing |
| `BackupHealthy` | Last backup CronJob succeeded | Last CronJob run failed |
| `AuthConfigured` | oauth2-proxy Secret and config are in sync | Secret missing or config invalid |

---

## 7. Reconciliation Logic

The reconciler runs on every `FoundryServer` event and on a periodic resync (default 10 minutes). It follows an ordered set of steps; any error short-circuits remaining steps and triggers an exponential backoff retry.

### 7.1 Reconcile order

```
1.  Fetch FoundryServer from API server; return if not found (deleted).
2.  Set status.phase = Provisioning if not already Running.
3.  Ensure PVC exists and is Bound            → StorageReady condition.
4.  Ensure cert-manager Certificate exists     → CertificateReady condition.
    (Check accessible Issuer first; surface descriptive error if not found.)
5.  Render Caddyfile → reconcile ConfigMap.
6.  Render oauth2-proxy config → reconcile ConfigMap + Secret.
7.  Render Deployment (all three containers)   → apply server-side.
8.  Ensure Service (ClusterIP) exists.
9.  Ensure HTTPRoute + ReferenceGrant exist.
10. Ensure backup CronJob exists (if backup.enabled).
11. Collect child resource states → update status conditions.
12. Set status.phase = Running / Degraded / Paused.
```

### 7.2 Ownership and garbage collection

All child resources are created with an OwnerReference pointing to the `FoundryServer`, with one exception:

**PVC lifecycle** is controlled by `spec.storage.data.reclaimPolicy`:
- `Retain` (default): The PVC is created without an OwnerReference. Deleting the `FoundryServer` leaves the PVC intact. The instance owner must delete it manually.
- `Delete`: The reconciler attaches a finalizer to the `FoundryServer`. On deletion, the finalizer explicitly deletes the PVC before removing itself, allowing the CR to be garbage collected. This is an explicit opt-in; it is not implemented via OwnerReference cascading.

All other child resources (Deployment, Services, ConfigMaps, HTTPRoute, Certificate, CronJob) carry OwnerReferences and are garbage collected automatically on CR deletion.

### 7.3 Pausing an instance

Setting `spec.paused: true` causes the reconciler to scale the Deployment to 0 replicas and set `status.phase = Paused`. The PVC and all networking resources are left intact. The backup CronJob is suspended.

> **Known gap (open question 4):** When paused, the Service has no endpoints and the Gateway returns a 502/503 to users who navigate to the instance URL. A future version may inject a static "server paused" page. For v1, document this behaviour prominently.

Setting `spec.paused: false` resumes normal operation.

---

## 8. Networking Design

### 8.1 Gateway API topology

The operator exclusively targets the Gateway API (`gateway.networking.k8s.io` v1). The legacy `networking.k8s.io/v1` Ingress resource is not supported and will not be added.

The Gateway API model separates infrastructure concerns (the Gateway, managed by cluster admins) from application routing concerns (the HTTPRoute, managed by the operator). This aligns well with a multi-tenant cluster where multiple `FoundryServer` instances share a single Gateway.

```yaml
# Operator-managed HTTPRoute (simplified)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-campaign
  namespace: foundry
spec:
  parentRefs:
    - name: prod-gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - my-campaign.vtt.example.com
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: my-campaign
          port: 4180               # oauth2-proxy port
```

A `ReferenceGrant` is created in the Gateway's namespace to permit cross-namespace HTTPRoute → Gateway attachment.

### 8.2 TLS with cert-manager

TLS is terminated at the Gateway, not inside the Pod. The operator creates a cert-manager `Certificate` resource whose resulting Secret is referenced directly by the Gateway listener. Caddy and oauth2-proxy communicate over plain HTTP on localhost — no in-Pod TLS is required.

| Parameter | Details |
|---|---|
| Issuer | Configurable via `spec.ingress.tls.issuerRef` |
| renewBefore | cert-manager default (30 days before expiry) |
| Secret namespace | Same namespace as the FoundryServer; ReferenceGrant emitted if Gateway is in a different namespace |
| Key algorithm | ECDSA P-256 |

### 8.3 Caddy sidecar

Caddy runs as a sidecar configured via a generated Caddyfile stored in a ConfigMap. A checksum annotation on the Deployment triggers a rolling restart when the Caddyfile changes.

```
# Generated Caddyfile (stored in ConfigMap foundry-caddy-<name>)
{
  # Admin API bound to localhost only — not exposed via Service or HTTPRoute
  admin 127.0.0.1:2019
  auto_https off               # TLS handled by Gateway
}

http://localhost:2019 {
  reverse_proxy localhost:30000 {
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host  {host}
  }
  header {
    Strict-Transport-Security "max-age=31536000"
    X-Content-Type-Options nosniff
  }
}
```

### 8.4 OAuth2-proxy sidecar

The oauth2-proxy sidecar intercepts all traffic on port 4180 before it reaches Caddy.

> **Open question 2:** The `/setup` route is required for initial Foundry configuration (licence entry, admin password). Its interaction with oauth2-proxy is unresolved. Until open question 2 is answered, do not add `/setup` to `skipAuthPaths` without a documented security rationale.

Paths listed in `spec.auth.skipAuthPaths` are forwarded without authentication. The defaults cover Foundry's Socket.IO websocket and module/system static assets, which are fetched before a user session is established.

| Config key | Source |
|---|---|
| `--provider` | `spec.auth.provider` |
| `--oidc-issuer-url` | `spec.auth.issuerURL` |
| `--client-id` | `spec.auth.clientID` |
| `--client-secret` | `spec.auth.clientSecretRef` (env var) |
| `--cookie-secret` | `spec.auth.cookieSecretRef` (env var) |
| `--email-domain` | `spec.auth.emailDomains[]` |
| `--skip-auth-regex` | `spec.auth.skipAuthPaths[]` |
| `--upstream` | `http://localhost:2019` (Caddy) |
| `--http-address` | `0.0.0.0:4180` |
| `--reverse-proxy` | `true` |

---

## 9. Storage Design

### 9.1 PersistentVolumeClaim

The operator creates a single PVC for each `FoundryServer` and mounts it at `/data` inside the foundry container. PVC lifecycle is controlled by `spec.storage.data.reclaimPolicy` (see section 7.2).

| Property | Default / notes |
|---|---|
| Mount path | `/data` (Foundry data directory) |
| Access mode | `ReadWriteOnce` |
| Size | `10Gi` (configurable via `spec.storage.data.size`) |
| StorageClass | Cluster default unless `spec.storage.data.storageClassName` is set |
| Resize | Operator patches PVC capacity if spec size increases; shrinking is rejected |

### 9.2 S3 backup via rclone CronJob

> **⚠ Open question 1 — blocking:** The backup approach is not finalised. The CronJob design below has a known scheduling hazard on multi-node clusters: a CronJob Pod mounting the same RWO PVC as the Foundry Pod will fail to start if scheduled to a different node. This section documents the current design intent; the implementation approach must be decided before work begins. See open question 1.

When `spec.storage.backup.enabled` is true, the operator creates a Kubernetes CronJob that runs an rclone sync from the Foundry data PVC to the configured S3 bucket.

**Retention:** The `spec.storage.backup.retention` field specifies the number of backups to retain, interpreted as days (`--max-age <retention>d` passed to rclone). This works correctly for a daily schedule. For schedules more frequent than daily, set `retention` to match the total number of backup files to retain (e.g. hourly schedule, keep 1 week = `retention: 168`). This limitation is a known simplification and may be revised in a future version.

**Data consistency (open question 3):** rclone sync on a live Foundry data directory may capture partial SQLite writes. The current design does not quiesce Foundry before backup. Backups should be considered crash-consistent, not write-consistent. This risk is accepted for v1 and must be documented prominently in the operator's user-facing documentation.

```yaml
# Simplified CronJob spec (operator-managed)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: foundry-backup-my-campaign
spec:
  schedule: '0 3 * * *'
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          # Node affinity to co-locate with the Foundry Pod (mitigates RWO scheduling hazard)
          # PROVISIONAL — subject to change based on decision in open question 1
          affinity:
            podAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      foundry.vtt.io/instance: my-campaign
                  topologyKey: kubernetes.io/hostname
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: my-campaign-data
                readOnly: true
          containers:
            - name: rclone
              image: rclone/rclone:1.67   # pin to a specific version
              envFrom:
                - secretRef:
                    name: foundry-backup-my-campaign-s3
              volumeMounts:
                - name: data
                  mountPath: /data
                  readOnly: true
              command:
                - rclone
                - sync
                - /data
                - ':s3:my-bucket/foundry/my-campaign/'
                - --s3-acl
                - private
                - --max-age
                - 7d
```

The status of the most recent CronJob run is reflected in `status.lastBackupTime` and `status.lastBackupStatus`.

---

## 10. RBAC & Security Considerations

### 10.1 ClusterRole (operator)

| API group | Resources | Verbs |
|---|---|---|
| `foundry.vtt.io` | foundryservers, foundryservers/status | get, list, watch, create, update, patch, delete |
| `apps` | deployments | get, list, watch, create, update, patch, delete |
| `core` | persistentvolumeclaims, services, configmaps, secrets | get, list, watch, create, update, patch, delete |
| `batch` | cronjobs | get, list, watch, create, update, patch, delete |
| `gateway.networking.k8s.io` | httproutes, referencegrants | get, list, watch, create, update, patch, delete |
| `cert-manager.io` | certificates | get, list, watch, create, update, patch, delete |
| `coordination.k8s.io` | leases | get, list, watch, create, update, patch, delete — required for leader election |

### 10.2 Security hardening

- All containers run as non-root. The foundry container image enforces UID 421; the sidecar images run as `nobody` (UID 65534).
- The Pod `securityContext` sets `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`, and drops all Linux capabilities.
- Secrets (OAuth2 client secrets, S3 credentials) are never stored in ConfigMaps. The operator never logs secret values.
- The Caddy admin endpoint is bound to `127.0.0.1:2019` (localhost only) and is not exposed via the Service or HTTPRoute.
- **Secret rotation:** Rotating the OAuth2 client secret or S3 credentials only requires updating the referenced Kubernetes Secret; the operator restarts affected containers via the checksum annotation mechanism.

---

## 11. Glossary

| Term | Definition |
|---|---|
| CRD | CustomResourceDefinition — Kubernetes extension mechanism for adding new resource types. |
| Foundry VTT | Foundry Virtual Tabletop — self-hosted application for running tabletop RPG sessions. |
| Gateway API | Kubernetes-native API for configuring ingress and mesh traffic routing (graduated GA in Kubernetes 1.28; supersedes the legacy Ingress resource). |
| GatewayClass | Cluster-scoped resource that identifies the controller implementation (e.g. Envoy Gateway, Cilium) backing a set of Gateways. |
| HTTPRoute | Gateway API resource that maps hostnames and path rules to backend Services. |
| ReferenceGrant | Gateway API resource that permits cross-namespace references, e.g. an HTTPRoute in namespace A attaching to a Gateway in namespace B. |
| cert-manager | Kubernetes add-on that automates TLS certificate issuance and renewal via ACME or internal CAs. |
| CEL | Common Expression Language — used in Kubernetes CRD validation rules to enforce invariants at admission time. |
| rclone | Open-source tool for syncing files to and from cloud storage providers including S3-compatible object stores. |
| oauth2-proxy | Reverse proxy that enforces OAuth2/OIDC authentication before forwarding requests to upstream services. |
| Caddy | Lightweight web server used here as a reverse-proxy sidecar for header manipulation and rate-limiting. |
| OwnerReference | Kubernetes metadata that links a child resource to its owner, enabling automatic garbage collection on owner deletion. |
| Leader election | Mechanism by which one replica of the operator is designated the active reconciler; others stand by. Required when running >1 operator replica. |
