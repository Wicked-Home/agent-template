# Foundry VTT Kubernetes Operator
## Design Document
*v0.1 · Draft*

---

## 1. Purpose & Scope

This document describes the design of a Kubernetes operator that manages the full lifecycle of Foundry Virtual Tabletop (Foundry VTT) server instances. The operator introduces the `FoundryServer` Custom Resource Definition (CRD) and a controller that reconciles the desired state expressed in that resource against the live cluster state.

The goals of the operator are:

- Provide a declarative, Kubernetes-native API for provisioning and configuring Foundry VTT instances.
- Manage all ancillary infrastructure — storage, networking, TLS, and access control — so that an operator (human) only needs to apply a single manifest.
- Enable reliable, low-friction backups of world and asset data to S3-compatible object storage.
- Route external traffic securely through a Caddy reverse-proxy sidecar and protect the admin interface with an OAuth/SSO sidecar.

Out of scope for v1:

- Multi-node / distributed Foundry deployments.
- Automatic Foundry VTT licence procurement.
- In-cluster world import/export tooling beyond backup schedules.
- Support for the legacy `networking.k8s.io/v1` Ingress resource. The operator targets the Gateway API exclusively; Ingress support will not be added.

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
```

---

## 4. Architecture Overview

The operator follows the standard controller-runtime pattern. A single Deployment runs the manager process, which watches `FoundryServer` resources cluster-wide (or within a configurable set of namespaces) and drives reconciliation.

### 4.1 Pod topology

Each `FoundryServer` instance maps to a single Kubernetes Pod (wrapped in a Deployment with replica count 1). The Pod contains three containers:

| Container | Image | Role |
|---|---|---|
| `foundry` | `felddy/foundryvtt:release` (configurable) | Main Foundry VTT process |
| `caddy` | `caddy:2-alpine` | Reverse proxy — header manipulation, rate-limiting |
| `oauth2-proxy` | `quay.io/oauth2-proxy/oauth2-proxy:latest` | SSO/OAuth2 enforcement in front of Caddy |

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
  │  foundry-operator (Deployment, 1 replica)           │
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

The operator is implemented in Go using the kubebuilder framework (`sigs.k8s.io/controller-runtime`). kubebuilder is the reference framework for Kubernetes operators maintained by the sig-api-machinery community. It was chosen over the alternative (operator-sdk) because operator-sdk is itself layered on top of kubebuilder, and the additional abstraction is not needed for a pure-Go operator.

Key kubebuilder capabilities used by this operator:

- **CRD generation:** Go struct annotations (`// +kubebuilder:validation:...`) drive automatic generation of the `FoundryServer` CRD YAML, including CEL validation rules and OpenAPI schema.
- **RBAC generation:** Controller method annotations (`// +kubebuilder:rbac:...`) generate the ClusterRole manifest, keeping permissions in sync with the code.
- **Webhook scaffolding:** kubebuilder generates the admission webhook boilerplate for the defaulting and validating webhooks.
- **envtest integration:** Controller tests run against a real API server binary via the envtest package, giving high-fidelity integration tests without a full cluster.
- **controller-runtime:** The underlying library provides the reconciler interface, event queuing, leader election, metrics endpoint, and health probes.

> **Note:** operator-sdk adds Ansible and Helm operator support on top of kubebuilder scaffolding. Since this operator is pure Go, kubebuilder alone is the right choice — there is no benefit to adding the operator-sdk layer.

### 4.5 Image management & custom registries

All three sidecar image fields accept any valid OCI image reference, including digest-pinned references and images hosted on private registries. This is the primary mechanism for supplying custom-built images.

| Spec field | Default image |
|---|---|
| `spec.foundry.image` | `felddy/foundryvtt:release` |
| `spec.caddy.image` | `caddy:2-alpine` |
| `spec.auth.image` | `quay.io/oauth2-proxy/oauth2-proxy:latest` |

For custom images, the recommended tagging convention embeds the upstream Foundry VTT version in the tag so that the running version is visible directly from the spec without inspecting the container:

```yaml
# Recommended tag format:  <registry>/<repo>:<foundry-version>-r<build>
spec:
  foundry:
    image: registry.example.com/foundry/foundryvtt:12.331-r1
  caddy:
    image: registry.example.com/foundry/caddy:2.8.4-r1
  auth:
    image: registry.example.com/foundry/oauth2-proxy:7.6.0-r1
```

Digest pinning is supported and recommended for production deployments, as it eliminates tag mutability risk:

```yaml
spec:
  foundry:
    image: registry.example.com/foundry/foundryvtt@sha256:abc123...
```

> **Note:** Building custom images is treated as a separate concern (a build pipeline project, not part of the operator itself). The operator simply consumes whatever image reference is provided in the spec. The key requirement for the Foundry image is that it must set the `FOUNDRY_VERSION` label so the operator can populate `status.foundryVersion`.
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

### 5.2 Full manifest with all fields

The following YAML shows every supported field with inline comments describing its purpose and default value. Mandatory fields are annotated with `# REQUIRED`.

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
    # Container image to use. The operator manages the tag by default.
    image: felddy/foundryvtt:release   # default
    # Foundry VTT licence key. Optional — if omitted, the key can be
    # entered via the Foundry web UI on first launch. Once entered it is
    # stored in /data and does not need to be supplied again.
    licenseKey:
      secretRef:
        name: foundry-license           # optional
        key: licenseKey
    # Foundry admin password (used for /setup). May also be a secretRef.
    adminPassword:
      secretRef:
        name: foundry-license
        key: adminPassword
    # Extra environment variables forwarded to the Foundry container.
    env: []
    # Resource requests and limits for the foundry container.
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: '2'
        memory: 2Gi

  # ── Storage ─────────────────────────────────────────────────────
  storage:
    # PVC configuration for /data (worlds, assets, configs).
    data:
      storageClassName: standard          # default from cluster
      size: 10Gi                          # default: 10Gi
      accessMode: ReadWriteOnce           # default
      # Optional: supply an existing PVC instead of creating one.
      existingClaim: ''

    # S3-compatible backup configuration.
    backup:
      enabled: false                      # default: false
      schedule: '0 3 * * *'               # cron — every day at 03:00
      retention: 7                        # number of backups to keep
      # Destination bucket URI understood by rclone.
      destination: s3://my-bucket/foundry/my-campaign/
      # Secret containing AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
      # and (optionally) AWS_ENDPOINT_URL for non-AWS providers.
      credentialsRef:
        name: foundry-s3-creds             # REQUIRED if enabled
      # rclone flags appended to every sync invocation.
      rcloneFlags: '--s3-acl private'

  # ── Networking ──────────────────────────────────────────────────
  ingress:
    # Fully-qualified public hostname for this instance.
    hostname: my-campaign.vtt.example.com  # REQUIRED

    # Gateway API settings.
    gateway:
      # Ref to the Gateway object that will own the HTTPRoute.
      gatewayRef:
        name: prod-gateway                 # REQUIRED
        namespace: gateway-system
        group: gateway.networking.k8s.io
        kind: Gateway
      # Name of the listener on the Gateway (must be an HTTPS listener).
      listenerName: https

    # cert-manager Certificate settings.
    tls:
      enabled: true                        # default: true
      # cert-manager Issuer or ClusterIssuer to use.
      issuerRef:
        name: letsencrypt-prod             # REQUIRED if tls.enabled
        kind: ClusterIssuer
        group: cert-manager.io
      # Secret that cert-manager will write the TLS certificate into.
      # Defaults to <name>-tls.
      secretName: ''

  # ── Caddy reverse proxy ──────────────────────────────────────────
  caddy:
    image: caddy:2-alpine                  # default
    # Additional Caddyfile snippets appended after the generated config.
    extraConfig: ''
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits:   { cpu: 200m, memory: 128Mi }

  # ── OAuth2 / SSO proxy ───────────────────────────────────────────
  auth:
    enabled: true                          # default: true
    image: quay.io/oauth2-proxy/oauth2-proxy:latest
    provider: oidc                         # oidc | github | google | azure
    # OIDC issuer URL (required for provider: oidc).
    issuerURL: https://auth.example.com/realms/vtt
    clientID: foundry-client               # REQUIRED if auth.enabled
    clientSecretRef:
      name: foundry-oauth-secret           # REQUIRED if auth.enabled
      key: clientSecret
    cookieSecretRef:
      name: foundry-oauth-secret
      key: cookieSecret
    # Email domains allowed to authenticate. Use '*' for any.
    emailDomains:
      - example.com
    # Paths bypassed by oauth2-proxy (Foundry's websocket, static assets).
    skipAuthPaths:
      - '^/socket\.io'
      - '^/modules'
      - '^/systems'
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits:   { cpu: 200m, memory: 128Mi }

  # ── Scheduling / operations ──────────────────────────────────────
  replicas: 1                              # always 1 for Foundry VTT
  paused: false                            # scale Deployment to 0 when true
  updateStrategy: RollingUpdate            # RollingUpdate | Recreate
  nodeSelector: {}
  tolerations: []
  affinity: {}
  priorityClassName: ''
```

### 5.3 Field reference

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

The operator writes back to `status.conditions` following the Kubernetes standard condition API. It also surfaces high-level summary fields for quick introspection.

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

All child resources (PVC excluded) are created with an OwnerReference pointing to the `FoundryServer`. Deleting the `FoundryServer` triggers cascading deletion of the Deployment, Services, ConfigMaps, HTTPRoute, Certificate, and CronJob. The PVC is intentionally orphaned on deletion to prevent accidental world loss; it can be manually deleted when no longer needed.

> **Note:** To delete the PVC automatically, set `spec.storage.data.reclaimPolicy: Delete`. This flag is absent from the manifest by default.

### 7.3 Pausing an instance

Setting `spec.paused: true` causes the reconciler to scale the Deployment to 0 replicas and set `status.phase = Paused`. The PVC and all networking resources are left intact. The backup CronJob is suspended. Setting `spec.paused: false` resumes normal operation.

---

## 8. Networking Design

### 8.1 Gateway API topology

The operator exclusively targets the Gateway API (`gateway.networking.k8s.io` v1). The legacy `networking.k8s.io/v1` Ingress resource is not supported and will not be added. This eliminates a dual code path in the reconciler and allows the operator to take full advantage of Gateway API features such as ReferenceGrant, BackendTLSPolicy, and typed route matching.

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
        - name: my-campaign        # ClusterIP Service
          port: 4180               # oauth2-proxy port
```

A `ReferenceGrant` is created in the Gateway's namespace to permit the cross-namespace HTTPRoute → Gateway attachment when the Gateway lives in a different namespace.

### 8.2 TLS with cert-manager

TLS is terminated at the Gateway, not inside the Pod. The operator creates a cert-manager `Certificate` resource whose resulting Secret is referenced directly by the Gateway listener. Caddy and oauth2-proxy communicate over plain HTTP on localhost — no in-Pod TLS is required. This is the recommended model for both Envoy Gateway and Cilium and removes all certificate-handling responsibility from the Caddy sidecar.

| Parameter | Details |
|---|---|
| Issuer | Configurable via `spec.ingress.tls.issuerRef`; defaults to a ClusterIssuer |
| renewBefore | cert-manager default (30 days before expiry) |
| Secret namespace | Same namespace as the FoundryServer; a ReferenceGrant is emitted if the Gateway is in a different namespace |
| Key algorithm | ECDSA P-256 (operator sets `spec.privateKey.algorithm: ECDSA`) |
| Gateway binding | Operator annotates the Certificate with the Gateway listener ref; cluster admin binds the Secret to the listener |

### 8.3 Caddy sidecar

Caddy runs as a sidecar and is configured via a generated Caddyfile stored in a ConfigMap. The operator renders the Caddyfile from the `FoundryServer` spec and updates the ConfigMap whenever relevant fields change; a checksum annotation on the Deployment triggers a rolling restart when the Caddyfile changes.

```
# Generated Caddyfile (stored in ConfigMap foundry-caddy-<name>)
{
  admin 0.0.0.0:2019
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

The oauth2-proxy sidecar intercepts all traffic on port 4180 before it reaches Caddy. Paths listed in `spec.auth.skipAuthPaths` are forwarded without authentication — this is essential for Foundry's Socket.IO websocket and module/system static assets, which are fetched before a user session is established.

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

The operator creates a single PVC for each `FoundryServer` and mounts it at `/data` inside the foundry container. The PVC lifecycle is decoupled from the `FoundryServer` lifecycle (see section 7.2).

| Property | Default / notes |
|---|---|
| Mount path | `/data` (Foundry data directory) |
| Access mode | `ReadWriteOnce` |
| Size | `10Gi` (configurable via `spec.storage.data.size`) |
| StorageClass | Cluster default unless `spec.storage.data.storageClassName` is set |
| Resize | Operator patches PVC capacity if spec size increases; shrinking is rejected |

### 9.2 S3 backup via rclone CronJob

When `spec.storage.backup.enabled` is true, the operator creates a Kubernetes CronJob that runs an rclone sync from the Foundry data PVC to the configured S3 bucket. The CronJob mounts the same PVC as the Foundry Deployment (read-only) and loads S3 credentials from a Secret derived from `spec.storage.backup.credentialsRef`.

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
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: my-campaign-data
                readOnly: true
          containers:
            - name: rclone
              image: rclone/rclone:latest
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
```

Backup retention is enforced by a post-sync hook that calls `rclone delete` with a `--max-age` filter derived from `spec.storage.backup.retention` days. The status of the most recent CronJob run is reflected in `status.lastBackupTime` and `status.lastBackupStatus`.

---

## 10. RBAC & Security Considerations

The operator's ServiceAccount must hold the following cluster-level and namespaced permissions:

### 10.1 ClusterRole (operator)

| API group | Resources | Verbs |
|---|---|---|
| `foundry.vtt.io` | foundryservers, foundryservers/status | get, list, watch, create, update, patch, delete |
| `apps` | deployments | get, list, watch, create, update, patch, delete |
| `core` | persistentvolumeclaims, services, configmaps, secrets | get, list, watch, create, update, patch, delete |
| `batch` | cronjobs | get, list, watch, create, update, patch, delete |
| `gateway.networking.k8s.io` | httproutes, referencegrants | get, list, watch, create, update, patch, delete |
| `cert-manager.io` | certificates | get, list, watch, create, update, patch, delete |

### 10.2 Security hardening

- All containers run as non-root. The foundry container image enforces UID 421; the sidecar images run as `nobody` (UID 65534).
- The Pod `securityContext` sets `runAsNonRoot: true`, `seccompProfile: RuntimeDefault`, and drops all Linux capabilities.
- Secrets (OAuth2 client secrets, S3 credentials) are never stored in ConfigMaps. The operator never logs secret values.
- The admin endpoint of Caddy (port 2019) is bound to localhost only and is not exposed via the Service or HTTPRoute.
- **Secret rotation:** Rotating the OAuth2 client secret or S3 credentials only requires updating the referenced Kubernetes Secret; the operator will restart affected containers via the checksum annotation mechanism.

---

## 11. Open Questions & Future Work

| Topic | Notes |
|---|---|
| Foundry licence validation | Should the operator surface licence expiry in `status.conditions`? Requires polling the Foundry `/api/status` endpoint. |
| Multi-world PVC strategy | Single PVC with sub-directories is simpler to operate; separate PVCs per world allow independent resize and backup schedules. |
| Backup compression | rclone supports `--compress`; worth enabling for large asset and audio collections to reduce S3 storage costs. |
| Metrics & alerting | Expose Prometheus metrics: backup age, certificate TTL remaining, pod restart count. A ServiceMonitor CRD would enable Prometheus Operator integration. |
| Version pinning & auto-update | Decide whether the operator should auto-update the Foundry image tag or require an explicit spec change. Consider digest pinning for reproducibility. |
| Foundry module management | Out of scope for v1. A future `FoundryModule` CRD could declaratively manage installed modules and systems. |
| Multi-tenant Gateway sharing | Document the exact ReferenceGrant pattern when many `FoundryServer` instances share one Gateway across namespaces. |
| Restore workflow | Operator currently only writes backups. A status-driven restore (e.g. `spec.storage.backup.restoreFrom`) would complete the data recovery story. |

---

## 12. Glossary

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
