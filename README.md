# Ecommerce AWS EKS DevOps

Infrastructure-as-code and GitOps configuration for a 23-microservice ecommerce platform (based on the [OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo)), running on Amazon EKS across two environments.

This repo contains the **infrastructure, Kubernetes manifests, and GitOps configuration**. The application source code lives in a separate repo, [`ecommerce-source-code`](https://github.com/Besso2003/ecommerce-source-code).

![Terraform module and environment architecture](docs/images/terraform-architecture.svg)

## Architecture at a glance

```
Three EKS clusters, hub-and-spoke:

  platform cluster (hub)   -- runs ArgoCD only
        |
        |-- deploys to -->  dev cluster   (spoke, workloads only)
        |-- deploys to -->  prod cluster  (spoke, workloads only)
```

```
dev:   in-cluster PostgreSQL on EBS, cost-optimized, frequently
        destroyed and recreated
prod:  Amazon RDS PostgreSQL, External Secrets Operator pulling
        credentials from AWS Secrets Manager, EKS Pod Identity
```

Every AWS permission a workload needs (EBS CSI, External Secrets Operator) is granted through **EKS Pod Identity** - no IAM credentials are ever stored in a Secret, a ConfigMap, or this repo.

## Repository structure

```
Terraform/        Infrastructure as code - VPC, EKS, IAM, ECR, RDS,
                    one folder per environment, shared modules
k8s/               Kubernetes manifests, Kustomize base + overlays
                    for dev and prod
argocd/            GitOps configuration - App of Apps pattern,
                    cluster registration
docs/images/       Architecture diagrams and screenshots referenced
                    by the READMEs below
.github/workflows/ Terraform plan-on-PR CI (the app build/push
                    pipeline lives in the separate source-code repo)
scripts/           Local helper scripts (e.g. safe-destroy.sh)
```

Each of these has its own, more detailed README:

| Folder | Covers |
|---|---|
| [`Terraform/README.md`](Terraform/README.md) | Module structure, apply order, the IRSA → Pod Identity migration, cost, and a troubleshooting guide for every recurring AWS issue this project has hit |
| [`k8s/README.md`](k8s/README.md) | Service inventory, probe design, StatefulSet rationale, secrets strategy, and how dev's and prod's databases differ |
| [`argocd/README.md`](argocd/README.md) | The hub-and-spoke design, how cluster registration is automated, and the GitOps lessons learned along the way |
| [`.github/workflows/README.md`](.github/workflows/README.md) | The Terraform plan-on-PR pipeline and the access/permission setup behind it |

## Getting started

```bash
# 1. One-time only, ever
cd Terraform/bootstrap && terraform apply

# 2. The ArgoCD hub must exist before anything else
cd ../environments/platform && terraform apply
kubectl apply -f argocd/root-app.yaml

# 3. Each workload environment registers itself with the hub automatically
cd ../dev && terraform apply
cd ../prod && terraform apply
```

From here, ArgoCD takes over - every change to `k8s/` that lands on `main` is deployed automatically. See `Terraform/README.md` for the full apply order, cost breakdown, and `Terraform/README.md`'s Troubleshooting section before your first `terraform destroy`.

## CI/CD

```
ecommerce-source-code (app code)
  -> push to main, path-filtered per service
  -> builds + pushes Docker images to ECR (ecommerce-dev/*)
  -> commits the new image tag back into THIS repo's k8s/overlays/dev
  -> ArgoCD picks up the change and deploys it automatically

THIS repo (infrastructure)
  -> any PR touching Terraform/ gets an automatic "terraform plan"
     for dev, prod, AND platform, posted as PR comments
  -> terraform apply stays manual - a deliberate, human-reviewed step
```

Authentication for both pipelines uses GitHub's OIDC federation - no AWS access keys are stored as secrets anywhere. The cross-repo commit from the app pipeline into this repo uses a dedicated GitHub App with narrowly-scoped, short-lived tokens.

## Known limitations

- `prod`'s database (RDS) and `dev`'s database (in-cluster StatefulSet on EBS) are intentionally different - dev prioritizes cost and disposability, prod prioritizes durability and managed backups.
- There is currently no Ingress Controller installed; both environments are reached via the `frontend-proxy` LoadBalancer Service directly. Revisit once a real domain is in place.
- `terraform apply` is manual for every environment, including `dev` - see `.github/workflows/README.md` for the reasoning.
- Two services referenced in earlier iterations of this project (`product-reviews`, `llm`) have known issues: `product-reviews` was removed from `dev` after a permanent crash caused by a missing protobuf service definition; `llm` has no corresponding source folder in `ecommerce-source-code` and hasn't been investigated yet.