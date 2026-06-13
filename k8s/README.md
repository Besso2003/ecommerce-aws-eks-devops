# Kubernetes Manifests

This folder contains all Kubernetes manifests for the ecommerce platform — 24 microservices deployed across three environments using Kustomize.

---

## Folder Structure

```
k8s/
├── base/                        # Reusable manifests — never applied directly
│   ├── accounting/
│   ├── ad-service/
│   ├── cart/
│   ├── checkout/
│   ├── currency/
│   ├── email/
│   ├── flagd/
│   ├── flagd-ui/
│   ├── fraud-detection/
│   ├── frontend/
│   ├── frontend-proxy/
│   ├── image-provider/
│   ├── kafka/
│   ├── llm/
│   ├── load-generator/
│   ├── payment/
│   ├── postgres/
│   ├── product-catalog/
│   ├── product-reviews/
│   ├── quote/
│   ├── recommendation-service/
│   ├── shipping/
│   ├── valkey/
│   └── network-policies/        # Zero-trust NetworkPolicy per service
│
└── overlays/                    # Environment-specific configuration
    ├── dev/
    │   ├── patches/             # Resource limits and replica overrides
    │   ├── ingress.yaml
    │   ├── namespace.yaml
    │   └── kustomization.yaml
    ├── staging/
    │   ├── patches/
    │   ├── namespace.yaml
    │   └── kustomization.yaml
    └── prod/
        ├── patches/
        ├── namespace.yaml
        └── kustomization.yaml
```

---

## What Each Service Folder Contains

Every service folder under `base/` follows this structure:

```
<service>/
  deployment.yaml       # Pod spec, image, env vars, probes, resource limits
  service.yaml          # ClusterIP service (or LoadBalancer for frontend-proxy)
  configmap.yaml        # All non-sensitive environment variables
  serviceaccount.yaml   # Dedicated service account (used for IRSA on EKS)
  hpa.yaml              # HorizontalPodAutoscaler — scales on CPU at 70%
  pdb.yaml              # PodDisruptionBudget — prevents total downtime during maintenance
  kustomization.yaml    # Lists all resources in this folder
```

Stateful services (postgres, kafka, valkey) also include:

```
  pvc.yaml              # PersistentVolumeClaim for durable storage
  sealed-secret.yaml    # Encrypted credentials stored safely in Git
```

---

## Environments

| Environment | Replicas | Resources | PDB minAvailable | Namespace |
|---|---|---|---|---|
| dev | 1 | small | 0 | dev |
| staging | 2 | medium | 1 | staging |
| prod | 3 | large | 2 | prod |

The only differences between environments are replica counts, resource limits, and PDB values. All other configuration is identical and lives in `base/`.

---

## Services

### Stateless Services (Deployment + Service + ConfigMap + HPA + PDB)

| Service | Port | Language | Dependencies |
|---|---|---|---|
| ad-service | 9099 | Java | flagd |
| cart | 8080 | .NET | valkey, flagd |
| checkout | 5050 | Go | cart, currency, email, payment, product-catalog, shipping, kafka, flagd |
| currency | 7001 | C++ | — |
| email | 6060 | Ruby | — |
| flagd | 8013 | Go | — |
| flagd-ui | 4000 | Elixir | flagd |
| fraud-detection | — | Kotlin | kafka, flagd |
| accounting | — | .NET | kafka, postgres |
| frontend | 8080 | TypeScript | all backend services |
| frontend-proxy | 8080 | Envoy | frontend, flagd, flagd-ui, image-provider |
| image-provider | 8081 | nginx | — |
| llm | 8000 | Python | — |
| load-generator | 8089 | Python | frontend-proxy |
| payment | 50051 | JavaScript | flagd |
| product-catalog | 8088 | Go | flagd |
| product-reviews | 3551 | Python | llm, postgres, flagd |
| quote | 8090 | PHP | — |
| recommendation-service | 1010 | Python | product-catalog, flagd |
| shipping | 50050 | Rust | quote |

### Stateful Services (Deployment + Service + ConfigMap + PVC + PDB)

| Service | Port | Purpose | Storage |
|---|---|---|---|
| postgres | 5432 | Relational database | 1Gi |
| kafka | 9092 | Message queue | 1Gi |
| valkey | 6379 | Redis-compatible cache | 512Mi |

---

## Network Policies

Zero-trust networking — all traffic is denied by default, then explicitly allowed per service. Each service has its own NetworkPolicy that only permits the exact connections shown in the architecture diagram.

Key policies:
- `default-deny-all.yaml` — blocks all ingress and egress for every pod
- `allow-dns.yaml` — allows all pods to reach kube-dns (required for service discovery)
- Per-service policies — only open the specific ports and directions each service needs

---

## Health Probes

Every service has probes configured to ensure Kubernetes only routes traffic to healthy pods and automatically restarts stuck ones. Three probe types are used depending on the service's characteristics.

### Probe Types

**startupProbe** — runs only during pod startup. Kubernetes waits for this to pass before running liveness or readiness probes. Used for slow-starting services like Kafka and Postgres that need time to initialize before accepting connections.

**readinessProbe** — tells Kubernetes when the pod is ready to receive traffic. A failing readiness probe removes the pod from the Service endpoints without restarting it. Used by every service.

**livenessProbe** — tells Kubernetes when to restart a pod. Only used when a stuck/deadlocked process won't recover on its own. Not used for Kafka — a slow broker is better than a restarting one.

### Probe Matrix

| Service | Startup | Readiness | Liveness | Method |
|---|---|---|---|---|
| product-catalog | ✓ | ✓ | ✓ | gRPC |
| ad-service | ✓ | ✓ | ✓ | gRPC |
| recommendation-service | ✓ | ✓ | ✓ | gRPC |
| cart | ✓ | ✓ | ✓ | gRPC |
| checkout | ✓ | ✓ | ✓ | gRPC |
| payment | ✓ | ✓ | ✓ | gRPC |
| shipping | ✓ | ✓ | ✓ | gRPC |
| currency | ✓ | ✓ | ✓ | TCP |
| email | — | ✓ | ✓ | TCP |
| frontend | ✓ | ✓ | ✓ | HTTP GET / |
| frontend-proxy | — | ✓ | ✓ | HTTP GET / |
| image-provider | — | ✓ | ✓ | HTTP GET / |
| quote | — | ✓ | ✓ | HTTP GET / |
| load-generator | — | ✓ | ✓ | HTTP GET / |
| llm | — | ✓ | ✓ | HTTP GET / |
| flagd | — | ✓ | ✓ | HTTP GET /readyz |
| flagd-ui | — | ✓ | ✓ | TCP |
| fraud-detection | — | ✓ | — | TCP |
| accounting | — | ✓ | — | TCP |
| product-reviews | — | ✓ | ✓ | TCP |
| postgres | ✓ | ✓ | ✓ | pg_isready |
| kafka | ✓ | ✓ | ✗ | TCP |
| valkey | ✗ | ✓ | ✓ | TCP |

### Why Kafka has no livenessProbe

Kafka is a stateful message broker. If it becomes temporarily slow due to high load, a liveness probe restart would cause it to lose in-flight messages and force consumers to replay from their last committed offset. A slow Kafka is recoverable — a restarting Kafka causes cascading failures across checkout, fraud-detection, and accounting. The startupProbe gives Kafka up to 10 minutes to initialize, and the readinessProbe removes it from traffic if it becomes unresponsive, without triggering a destructive restart.

### Why Valkey has no startupProbe

Valkey (Redis-compatible) starts in under 1 second. A startupProbe would add unnecessary delay before the readiness check begins. The readinessProbe with a 5-second initial delay is sufficient.

---

## How to Apply

### Prerequisites

```bash
# Kind (local)
kind create cluster --name ecommerce
```

### Apply an environment

```bash
# Dev
kubectl apply -k k8s/overlays/dev

# Staging
kubectl apply -k k8s/overlays/staging

# Prod
kubectl apply -k k8s/overlays/prod
```

### Verify

```bash
kubectl get pods -n dev
kubectl get svc -n dev
kubectl get hpa -n dev
kubectl get pdb -n dev
kubectl get networkpolicy -n dev
kubectl get pvc -n dev
```

### Access locally (kind)

```bash
kubectl port-forward -n dev svc/frontend-proxy 8080:8080
# Open http://localhost:8080
```

## Ingress

The platform uses an **NGINX Ingress Controller** to expose the application outside the Kubernetes cluster. Instead of exposing individual services, all external traffic enters through a single Ingress resource and is routed to the `frontend-proxy` service, which acts as the platform's gateway.

### Traffic Flow

```text
User → NGINX Ingress → frontend-proxy (Envoy) → Microservices
```

### Benefits

* Provides a single entry point for the entire application.
* Simplifies service exposure by avoiding multiple LoadBalancer services.
* Enables host-based routing using a custom domain.
* Supports future SSL/TLS termination and advanced routing rules.
* Keeps internal microservices accessible only within the cluster.

### Access

The application is available through:

```text
http://ecommerce.local
```

For local environments, add the domain to your hosts file and point it to the Ingress Controller address.

---

## Key Design Decisions

**Kustomize over Helm** — Kustomize is built into kubectl, requires no templating language, and is natively supported by ArgoCD. Helm adds complexity that isn't needed when you control all the manifests.

**One service account per service** — each pod has its own Kubernetes ServiceAccount. On EKS this maps to a dedicated IAM role via IRSA, giving each service only the AWS permissions it needs.

**ConfigMaps for all config** — All non-sensitive settings (service endpoints, ports, environment variables, feature flags, and runtime configuration) are stored in Kubernetes ConfigMaps, eliminating hardcoded values from deployment manifests.

**Sealed Secrets for secure secret management** — Sensitive data such as database passwords, API keys, and credentials are encrypted using Sealed Secrets, enabling secure storage in Git repositories while preventing exposure of plaintext secrets.

**Externalized configuration references** — Deployments consume ConfigMaps and Secrets through Kubernetes references (configMapRef, secretRef, and environment variable mappings), allowing configuration updates and secret rotation without modifying application code.

**HPA at 70% CPU** — scales up before services become saturated. `minReplicas: 1` in dev/staging, `minReplicas: 2` in prod ensures no single point of failure.

**PDB prevents total downtime** — during node drain or rolling updates, Kubernetes will not evict pods if it would violate the PodDisruptionBudget. `minAvailable: 2` in prod means at least 2 replicas always stay running.

**PVCs for stateful services** — postgres, kafka, and valkey use PersistentVolumeClaims so data survives pod restarts. On kind, the local-path provisioner creates PVs automatically. On EKS, the EBS CSI driver provisions AWS EBS volumes automatically.

---

## Adding a New Service

1. Create `k8s/base/<service-name>/` with all required files
2. Add to `k8s/overlays/dev/kustomization.yaml` resources and patches
3. Add to `k8s/overlays/staging/kustomization.yaml`
4. Add to `k8s/overlays/prod/kustomization.yaml`
5. Add a NetworkPolicy in `k8s/base/network-policies/`
6. Apply: `kubectl apply -k k8s/overlays/dev`

---

## Troubleshooting

```bash
# Pod not starting
kubectl describe pod -n dev -l app=<service>
kubectl logs -n dev deployment/<service> --tail=20

# Service not reachable
kubectl get svc -n dev
kubectl get networkpolicy -n dev

# HPA not scaling
kubectl top pods -n dev
kubectl describe hpa -n dev <service>

# PVC not binding
kubectl get pvc -n dev
kubectl describe pvc -n dev <service>-pvc
```