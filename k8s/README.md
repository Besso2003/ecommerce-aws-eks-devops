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
 
Stateful services (postgres, kafka, valkey) use a different structure:
 
```
<service>/
  statefulset.yaml      # StatefulSet with volumeClaimTemplates (replaces deployment.yaml + pvc.yaml)
  service-headless.yaml # Headless service for stable DNS per pod
  configmap.yaml        # Non-sensitive environment variables
  serviceaccount.yaml   # Dedicated service account (used for IRSA on EKS)
  sealed-secret.yaml    # Encrypted credentials stored safely in Git (postgres only)
  pdb.yaml              # PodDisruptionBudget
  kustomization.yaml    # Lists all resources in this folder
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

### Stateful Services (StatefulSet + Headless Service + ConfigMap + PDB)
 
| Service | Port | Purpose | Storage |
|---|---|---|---|
| postgres | 5432 | Relational database | 1Gi |
| kafka | 9092 | Message queue | 1Gi |
| valkey | 6379 | Redis-compatible cache | 512Mi |

## Stateful Services
 
Postgres, Kafka, and Valkey are deployed as **StatefulSets** rather than Deployments. This is a deliberate architectural decision based on how these services manage state.
 
### Why StatefulSet over Deployment
 
A Deployment treats all pods as identical and interchangeable. For stateless services this is correct — any pod can handle any request. For stateful services this causes problems:
 
- A Deployment pod gets a random name (`postgres-59944c77df-t8gkl`) that changes on every restart
- PVCs are not guaranteed to reattach to the same pod
- No ordered startup or shutdown — a database that starts before its storage is mounted will corrupt data
A StatefulSet solves all three:
 
| Feature | Deployment | StatefulSet |
|---|---|---|
| Pod name | Random, changes on restart | Stable (`postgres-0`, `kafka-0`) |
| PVC binding | Manual PVC, any pod can claim it | Each pod gets its own PVC, always reattaches |
| Startup order | Parallel, random | Ordered (0 → 1 → 2) |
| Shutdown order | Parallel, random | Reverse ordered (2 → 1 → 0) |
| DNS | `postgres.dev.svc.cluster.local` | `postgres-0.postgres-headless.dev.svc.cluster.local` |
 
### Headless Service
 
Each StatefulSet has a **headless service** (`clusterIP: None`) alongside it. A regular service gives you a single virtual IP that load-balances across all pods. A headless service skips the virtual IP and gives each pod a stable, predictable DNS entry:
 
```text
postgres-0.postgres-headless.dev.svc.cluster.local
kafka-0.kafka-headless.dev.svc.cluster.local
valkey-0.valkey-headless.dev.svc.cluster.local
```
 
This matters for databases and brokers where clients need to connect to a **specific instance**, not a random one behind a load balancer.
 
### volumeClaimTemplates
 
Instead of a separate `pvc.yaml`, StatefulSets use `volumeClaimTemplates` inside the spec. Kubernetes automatically creates one PVC per pod and names it predictably:
 
```text
postgres-data-postgres-0
kafka-data-kafka-0
valkey-data-valkey-0
```
 
If `postgres-0` is deleted and recreated, it automatically reattaches to `postgres-data-postgres-0` — the data is never lost.


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
| image-provider | — | ✓ | ✓ | TCP |
| quote | — | ✓ | ✓ | TCP |
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

## Secrets Management
 
Sensitive credentials (database passwords, API keys) are managed using **Sealed Secrets**. Plain Kubernetes Secrets are base64-encoded and unsafe to commit to Git. Sealed Secrets encrypt the values using the cluster's public key — only the cluster can decrypt them.
 
```text
secret.yaml (plain text, in .gitignore)
     ↓
kubeseal --scope cluster-wide
     ↓
sealed-secret.yaml (encrypted, safe to commit)
     ↓
Sealed Secrets Controller decrypts at runtime
     ↓
Kubernetes Secret (only exists inside the cluster)
```
 
Plain `secret.yaml` files are in `.gitignore` and never committed. Only `sealed-secret.yaml` files are in Git.
 
On EKS, secrets will be migrated to **AWS Secrets Manager** with the External Secrets Operator for centralized secret management and automatic rotation.

---

## How to Apply
 
### Prerequisites
 
```bash
# Kind (local)
kind create cluster --name ecommerce
 
# Install Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
 
# Install NGINX Ingress Controller (kind)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.2/deploy/static/provider/kind/deploy.yaml
kubectl label node ecommerce-control-plane ingress-ready=true
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
kubectl get statefulsets -n dev
```
 
### Access locally (kind)
 
```bash
# Add to /etc/hosts
echo "127.0.0.1 ecommerce.local" | sudo tee -a /etc/hosts
 
# Port-forward NGINX ingress
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
 
# Open in browser
http://ecommerce.local:8080
```
 
---
 
## Ingress
 
The platform uses an **NGINX Ingress Controller** to expose the application outside the Kubernetes cluster. Instead of exposing individual services, all external traffic enters through a single Ingress resource and is routed to the `frontend-proxy` service, which acts as the platform's gateway.
 
### Traffic Flow
 
```text
User → NGINX Ingress → frontend-proxy (Envoy) → Microservices
```
 
### Benefits
 
- Provides a single entry point for the entire application
- Simplifies service exposure by avoiding multiple LoadBalancer services
- Enables host-based routing using a custom domain
- Supports future SSL/TLS termination and advanced routing rules
- Keeps internal microservices accessible only within the cluster
### Local vs EKS
 
| Environment | Ingress Controller | Address |
|---|---|---|
| dev (kind) | NGINX | `http://ecommerce.local:8080` |
| staging (EKS) | AWS ALB | `https://staging.yourdomain.com` |
| prod (EKS) | AWS ALB | `https://yourdomain.com` |
 
---
 
## Key Design Decisions
 
**Kustomize over Helm** — Kustomize is built into kubectl, requires no templating language, and is natively supported by ArgoCD. Helm adds complexity that isn't needed when you control all the manifests.
 
**StatefulSet for stateful services** — Postgres, Kafka, and Valkey use StatefulSets instead of Deployments. This ensures stable pod names, guaranteed PVC reattachment, and ordered startup/shutdown. Each StatefulSet has a headless service for stable per-pod DNS.
 
**One service account per service** — each pod has its own Kubernetes ServiceAccount. On EKS this maps to a dedicated IAM role via IRSA, giving each service only the AWS permissions it needs.
 
**ConfigMaps for all config** — all non-sensitive settings are stored in Kubernetes ConfigMaps, eliminating hardcoded values from deployment manifests.
 
**Sealed Secrets for secure secret management** — sensitive data is encrypted using Sealed Secrets, enabling secure storage in Git repositories while preventing exposure of plaintext secrets.
 
**HPA at 70% CPU** — scales up before services become saturated. `minReplicas: 1` in dev/staging, `minReplicas: 2` in prod ensures no single point of failure.
 
**PDB prevents total downtime** — during node drain or rolling updates, Kubernetes will not evict pods if it would violate the PodDisruptionBudget. `minAvailable: 2` in prod means at least 2 replicas always stay running.
 
**Zero-trust NetworkPolicy** — all pod-to-pod traffic is denied by default. Each service has an explicit NetworkPolicy that only permits the exact connections it needs based on the architecture diagram.
 
**Recreate strategy for StatefulSets** — stateful services use `updateStrategy: type: RollingUpdate` with `Recreate` behavior via the StatefulSet controller, ensuring the old pod fully terminates and releases its PVC before the new pod starts.
 
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
 
# StatefulSet pod not starting
kubectl describe pod -n dev <service>-0
kubectl logs -n dev <service>-0 --tail=20
 
# Service not reachable
kubectl get svc -n dev
kubectl get networkpolicy -n dev
 
# HPA not scaling
kubectl top pods -n dev
kubectl describe hpa -n dev <service>
 
# PVC not binding
kubectl get pvc -n dev
kubectl describe pvc -n dev <service>-data-<service>-0
 
# Sealed secret not decrypting
kubectl get sealedsecret -n dev
kubectl describe sealedsecret -n dev <secret-name>
 
# Ingress not routing
kubectl get ingress -n dev
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=20
```