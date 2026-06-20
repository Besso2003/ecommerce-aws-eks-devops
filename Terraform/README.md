# Terraform Infrastructure

This folder contains all Infrastructure as Code for the project, covering three EKS clusters (`platform`, `dev`, `prod`), their supporting AWS resources, and the GitOps wiring that connects them to ArgoCD.

## Folder Structure

```
Terraform/
├── bootstrap/          Applied once, never destroyed. Creates the S3
│                        backend bucket used to store all other state.
├── modules/             Reusable building blocks
│   ├── vpc/              VPC, subnets, NAT, IGW, S3 gateway endpoint
│   ├── iam/              EKS cluster role + node role (no OIDC, avoids
│   │                      a circular dependency with the eks module)
│   ├── eks/              Cluster, node group, addons, OIDC provider,
│   │                      EBS CSI role, External Secrets IAM role
│   ├── ecr/              19 repositories with lifecycle policies
│   └── rds/              PostgreSQL instance, Secrets Manager secret
│                          (prod only)
└── environments/        One folder per deployable stack
    ├── platform/          The ArgoCD hub. VPC + EKS + ArgoCD Helm
    │                       release only. No ECR, no RDS.
    ├── dev/                VPC + EKS + ECR. Postgres runs in-cluster
    │                       on EBS. Registers itself with the hub.
    └── prod/               VPC + EKS + ECR + RDS + External Secrets
                            Operator. Registers itself with the hub.
```

## Module Dependency Graph

![Terraform module and environment architecture](../docs/images/terraform-architecture.svg)

```
vpc   -- no dependencies
iam   -- no dependencies
eks   -- needs vpc + iam outputs
         creates its own OIDC provider and EBS CSI role internally
         to avoid a circular dependency between eks and iam
ecr   -- no dependencies
rds   -- needs vpc outputs (prod only)
```

Each environment also creates an `argocd-manager` ServiceAccount on its own cluster, then writes a cluster-registration Secret directly into the `platform` cluster's `argocd` namespace using a second, aliased `kubernetes` provider. See `argocd/README.md` for the full explanation of this mechanism.

## Apply Order

The `platform` environment must exist before `dev` or `prod` are applied, since their Terraform writes a registration secret into the hub's cluster.

```bash
cd Terraform/bootstrap && terraform apply   # one time only, ever

cd Terraform/environments/platform && terraform apply
cd Terraform/environments/dev && terraform apply
cd Terraform/environments/prod && terraform apply
```

Each environment is fully independent after that — `dev` and `prod` can be destroyed and re-applied in any order without affecting each other or the hub.

## Cost Awareness

| Environment | Approx. cost/month while running |
|---|---|
| platform | ~$87 (1 × t3.small + EKS control plane) |
| dev | ~$249 (2 × m7i-flex.large + NAT + EKS control plane) |
| prod | ~$413 (4 × m7i-flex.large + 3 NAT + RDS + EKS control plane) |

All three are designed to be destroyed when not actively in use. Destroy in the reverse of the apply order above (`prod`/`dev` first, `platform` last) if you want the hub to remain reachable while tearing down workload clusters.

## Destroying an Environment

Always remove Kubernetes-managed resources before running `terraform destroy`. Skipping this step is the single most common cause of a stuck destroy (see Troubleshooting below).

```bash
kubectl delete -k k8s/overlays/<env>/
sleep 60
cd Terraform/environments/<env>
terraform destroy
```

## Troubleshooting

### `terraform destroy` hangs on the Internet Gateway or VPC for 10+ minutes

**Cause:** A Kubernetes `Service` of type `LoadBalancer` (e.g. `frontend-proxy`) created a classic ELB that was never cleaned up before the cluster was deleted. The ELB's network interfaces and security group keep the VPC from detaching its Internet Gateway, and the VPC itself can't be deleted while that security group still exists.

**Fix:**

```bash
# 1. Find the VPC behind the stuck IGW
aws ec2 describe-internet-gateways \
  --internet-gateway-ids <igw-id-from-the-stuck-output> \
  --region eu-north-1 \
  --query 'InternetGateways[0].Attachments[0].VpcId' \
  --output text

# 2. Check for a leftover classic ELB in that VPC
aws elb describe-load-balancers \
  --region eu-north-1 \
  --query 'LoadBalancerDescriptions[*].[LoadBalancerName,VPCId]' \
  --output table

# 3. Delete it
aws elb delete-load-balancer \
  --load-balancer-name <name-from-step-2> \
  --region eu-north-1

# 4. If the VPC destroy is still stuck afterward, check for a leftover
#    k8s-elb-* security group and delete it directly
aws ec2 describe-security-groups \
  --region eu-north-1 \
  --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table

aws ec2 delete-security-group \
  --group-id <sg-id-starting-with-k8s-elb> \
  --region eu-north-1
```

The running `terraform destroy` will pick this up automatically within its next retry — no need to restart it.

### `Error: creating Secrets Manager Secret ... already scheduled for deletion`

**Cause:** Secrets Manager keeps a deleted secret in a 7-day recovery window by default. Re-applying an environment shortly after destroying it tries to recreate a secret with the same name, which AWS rejects while the old one is still pending deletion.

**Fix:**

```bash
aws secretsmanager delete-secret \
  --secret-id <secret-name, e.g. ecommerce-prod-rds-password> \
  --force-delete-without-recovery \
  --region eu-north-1
```

Then re-run `terraform apply`.

### `VcpuLimitExceeded` when a node group is creating

**Cause:** The AWS account's On-Demand vCPU quota for the relevant instance family has been reached. This is easy to hit when `dev` and `prod` are both running at once on a default (low) quota.

**Fix (short term):** Destroy one environment to free up quota before creating the other.

**Fix (long term):** Request a quota increase:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 32 \
  --region eu-north-1
```

This is a free request reviewed by AWS and is not always instant.

### `helm_release` destroy fails with `context deadline exceeded`

**Cause:** The underlying EKS cluster was already deleted (or became unreachable) before the Helm provider could confirm the chart was uninstalled. Terraform's state still references the release even though there is nothing left to uninstall.

**Fix:**

```bash
terraform state rm helm_release.<name>
terraform state rm kubernetes_namespace.<name>
terraform destroy
```

### `Cannot find version X for postgres` / `FreeTierRestrictionError` on RDS

**Cause:** Not every PostgreSQL engine version is available in every region, and AWS Free Tier accounts reject certain `aws_db_instance` settings (non-zero `backup_retention_period`, `multi_az = true`).

**Fix:** Check available versions before setting `postgres_version`:

```bash
aws rds describe-db-engine-versions \
  --engine postgres \
  --region eu-north-1 \
  --query 'DBEngineVersions[*].EngineVersion' \
  --output table
```

For Free Tier accounts, keep `multi_az = false`, `backup_retention_days = 0`, and `skip_final_snapshot = true` in the environment's RDS module call.

## See Also

- `argocd/README.md` — how the hub-and-spoke ArgoCD setup is wired into these environments
- `k8s/README.md` — the Kubernetes manifests these environments ultimately run