# Terraform Infrastructure

This folder contains all Infrastructure as Code for the project, covering three EKS clusters (`platform`, `dev`, `prod`), their supporting AWS resources, and the GitOps wiring that connects them to ArgoCD.

## Folder Structure

```
Terraform/
├── bootstrap/          Applied once, never destroyed. Creates the S3
│                        backend bucket, the GitHub OIDC provider, and
│                        the two IAM roles GitHub Actions assumes
│                        (see "GitHub Actions Authentication" below).
├── modules/             Reusable building blocks
│   ├── vpc/              VPC, subnets, NAT, IGW, S3 gateway endpoint
│   ├── iam/              EKS cluster role + node role (no OIDC, avoids
│   │                      a circular dependency with the eks module)
│   ├── eks/              Cluster, node group, addons, Pod Identity
│   │                      Associations, EBS CSI role, External Secrets
│   │                      IAM role, and the read-only EKS Access Entry
│   │                      used by GitHub Actions' terraform-plan role
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
         creates its own Pod Identity Associations and EBS CSI role
         internally to avoid a circular dependency between eks and iam
ecr   -- no dependencies
rds   -- needs vpc outputs (prod only)
```

Each environment also creates an `argocd-manager` ServiceAccount on its own cluster, then writes a cluster-registration Secret directly into the `platform` cluster's `argocd` namespace using a second, aliased `kubernetes` provider. See `argocd/README.md` for the full explanation of this mechanism.

## AWS Authentication: IRSA → Pod Identity Migration

This project originally used **IRSA** (IAM Roles for Service Accounts) to give the EBS CSI driver and External Secrets Operator permission to call AWS APIs from inside the cluster. It has since been migrated to **EKS Pod Identity**, AWS's newer and simpler mechanism for the same purpose. Both are documented here because the reasoning behind the switch is itself a useful record of a real tradeoff decision.

### What IRSA looked like

```hcl
# An OIDC provider had to be created per cluster
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Each IAM role's trust policy referenced that OIDC provider directly,
# scoped to one specific namespace:serviceaccount combination
resource "aws_iam_role" "ebs_csi" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${...}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}
```

The matching Kubernetes ServiceAccount also needed an explicit annotation:

```yaml
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<role-name>
```

For Helm-installed components (External Secrets Operator), this annotation had to be injected via a Helm `set` value, since the chart's default ServiceAccount has no annotation of its own:

```hcl
resource "helm_release" "external_secrets" {
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.external_secrets_role_arn
  }
}
```

### Why it was replaced

IRSA worked, but it had real, repeated operational friction in this project specifically:

- The annotation lived outside Terraform's direct control on cluster rebuilds that didn't go through the Helm `set` block consistently, requiring a manual `kubectl annotate` step to be re-applied after some reinstalls.
- Each IAM role's trust policy was tied to one specific cluster's OIDC provider, making the same role harder to reason about across `dev` and `prod` independently.
- AWS has explicitly positioned Pod Identity as the simpler, currently-recommended mechanism for new EKS workloads going forward.

### What Pod Identity replaced it with

No OIDC provider, no annotation, no Helm `set` value. The IAM role trusts the Pod Identity service directly:

```hcl
resource "aws_iam_role" "ebs_csi" {
  name = "${local.name_prefix}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}
```

A separate, explicit resource maps a namespace + ServiceAccount name to that role, instead of relying on an annotation:

```hcl
resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_addon.pod_identity]
}
```

The `eks-pod-identity-agent` EKS addon (a small DaemonSet) must be installed on the cluster for this to work; it was already present in the addon list before the migration, just unused until now.

The same pattern was applied to both `ebs_csi` and `external_secrets` roles, in both `dev` and `prod`. `platform` has no AWS-permission-bearing workloads and was unaffected by this change.

### A real gotcha hit during the migration

After switching `secretstore.yaml`'s AWS provider config to the Pod Identity pattern (removing its `auth.jwt.serviceAccountRef` block, since `serviceAccountRef` cannot coexist with Pod Identity), the `ClusterSecretStore` kept reverting to the old IRSA-style config and failing with `unable to create session: an IAM role must be associated with service account`, even after the IAM and association changes were confirmed correct on the AWS side.

The cause was **ArgoCD's `selfHeal`**, not a misconfiguration: the fix had only been applied directly to the live cluster via `kubectl apply`, not committed to git. Since ArgoCD's `ecommerce-prod` Application has `selfHeal: true`, every manual edit to a resource it manages gets detected as drift from git and reverted automatically, often within seconds. See `argocd/README.md` → "Known Limitations" for the general rule this implies: **any fix to an ArgoCD-managed resource must be committed and pushed, never applied directly to the cluster, or it will not persist.**

## GitHub Actions Authentication

Two CI/CD pipelines run against this AWS account, both authenticating via **OIDC federation** — no AWS access keys are stored as GitHub secrets anywhere. Both the OIDC provider and both IAM roles below live in `Terraform/bootstrap/`, since they're account-wide and don't belong to any one environment.

```
aws_iam_openid_connect_provider.github_actions
  -- one OIDC trust relationship between AWS and 
     token.actions.githubusercontent.com, shared by both roles below

github-actions-ecr-push
  -- used by ecommerce-source-code's build pipeline
  -- trust policy scoped to: repo:Besso2003/ecommerce-source-code:
     ref:refs/heads/main
  -- permissions: push images only, only to ecommerce-dev/* ECR
     repositories. Cannot touch ecommerce-prod/*, cannot touch
     anything outside ECR.

github-actions-terraform-plan
  -- used by THIS repo's .github/workflows/terraform-plan.yml
  -- trust policy scoped to: repo:Besso2003/ecommerce-aws-eks-devops:*
     (any branch, since Pull Requests come from many branches)
  -- AWS-side permissions: the AWS-managed ReadOnlyAccess policy -
     can describe/read, can never create, modify, or delete anything
  -- Kubernetes-side permissions: a dedicated read-only ClusterRole
     (get, list, watch only), bound via an EKS Access Entry on every
     cluster (dev, prod, AND platform) - needed because some
     resources in each environment's main.tf are Kubernetes objects,
     not AWS objects (the argocd-manager ServiceAccount, its RBAC
     binding, the ArgoCD registration Secret, the External Secrets
     Helm release)
```

Full details on what each pipeline actually does are in `.github/workflows/README.md` (this repo's Terraform plan-on-PR) and `ecommerce-source-code`'s own `.github/workflows/README.md` (the app build/push pipeline).

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

Use `scripts/safe-destroy.sh` instead of running `terraform destroy` directly. It wraps the same destroy process with automatic detection and cleanup of the single most common cause of a stuck destroy in this project — see the next section for why this is necessary.

```bash
./scripts/safe-destroy.sh dev
./scripts/safe-destroy.sh prod
./scripts/safe-destroy.sh platform
```

What it does:

```
1. Deletes Kubernetes-managed resources (kubectl delete -k)
2. Starts "terraform destroy" running in the background
3. Watches its live output for the specific pattern that means
   a stuck Internet Gateway / VPC deletion (the same "Still
   destroying..." line repeating for ~70+ seconds)
4. The moment that's detected, automatically finds and deletes any
   leftover classic ELB and its "k8s-elb-*" security group in that
   environment's VPC - WHILE terraform destroy keeps running and
   retrying in the background
5. terraform destroy's own internal retries pick up the now-cleared
   blocker and finish normally - the script never needs to restart
   or re-run terraform itself
```

If you need to destroy manually for any reason, the equivalent steps are documented in the Troubleshooting section below, under "terraform destroy hangs on the Internet Gateway or VPC."

## Troubleshooting

### `terraform destroy` hangs on the Internet Gateway or VPC for 10+ minutes

**Cause:** A Kubernetes `Service` of type `LoadBalancer` (e.g. `frontend-proxy`) created a classic ELB. Depending on timing, this ELB sometimes isn't fully torn down by the time `terraform destroy` reaches the VPC - it can still be mid-creation or mid-deletion at that exact moment, which is why pre-emptively checking for it *before* starting `terraform destroy` doesn't always catch it. The ELB's network interfaces and security group keep the VPC from detaching its Internet Gateway, and the VPC itself can't be deleted while that security group still exists. `scripts/safe-destroy.sh` (see above) handles this automatically by watching for the stuck pattern *while destroy is running* rather than checking only beforehand.

**Manual fix, if not using the script:**

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

### `ClusterSecretStore` stuck on `InvalidProviderConfig: unable to create session: an IAM role must be associated with service account ...` after migrating to Pod Identity

**Cause:** This error message is specific to External Secrets Operator's AWS provider validating that no `auth.jwt.serviceAccountRef` is configured. If the `ClusterSecretStore` manifest in git still has that block, removing it directly on the cluster with `kubectl apply` will not help, because ArgoCD's `selfHeal` reverts the live resource back to whatever is committed in git.

**Fix:** Remove the `auth.jwt` block from the actual file under `k8s/overlays/<env>/external-secrets/secretstore.yaml`, then commit and push:

```bash
git add k8s/overlays/<env>/external-secrets/secretstore.yaml
git commit -m "fix: remove IRSA-style auth.jwt from ClusterSecretStore for Pod Identity"
git push
```

Confirm the live resource actually matches git afterward — `kubectl get clustersecretstore <name> -o yaml` should show no `auth` block under `spec.provider.aws`. If the ExternalSecret still shows a stale `SecretSyncedError` after the store becomes `Ready`, force an immediate re-sync rather than waiting for the refresh interval:

```bash
kubectl annotate externalsecret <name> -n <namespace> force-sync=$(date +%s) --overwrite
```

### `terraform plan` fails with `Error acquiring the state lock ... AccessDeniedException: ... dynamodb:PutItem`

**Cause:** This happens specifically when running `terraform plan` using a deliberately read-only role, such as GitHub Actions' `github-actions-terraform-plan`. State locking normally requires writing a temporary entry into DynamoDB before reading anything, which a true read-only role correctly cannot do.

**Fix:** Pass `-lock=false`. This is safe specifically because a read-only role can never run `apply` — there's no concurrent-write scenario to protect against:

```bash
terraform plan -lock=false
```

### `terraform plan` fails with `Error: failed to get shared config profile, bassant`

**Cause:** Every environment's `provider "aws"` block, and both `exec` blocks used to fetch a Kubernetes token, default to a personal AWS CLI profile (`var.aws_profile`, default `"bassant"`) that only exists on a local machine, not on a CI runner.

**Fix:** Override the variable for that one run:

```bash
terraform plan -var="aws_profile="
```

Each environment's `exec` blocks wrap the `--profile` flag in `concat(...)`, so the flag is only added when `aws_profile` is non-empty — passing an empty string makes both the AWS provider and `aws eks get-token` fall back to whatever credentials are already present as environment variables (the OIDC-issued ones, in CI). This has no effect on local usage, since the local default remains `"bassant"` unless explicitly overridden.

### A `ClusterRoleBinding` targeting an IAM role's ARN as a `User` subject silently never matches

**Cause:** When an IAM **role** (as opposed to an IAM **user**) authenticates to an EKS cluster, Kubernetes sees the STS *assumed-role session* identity (`arn:aws:sts::<account>:assumed-role/<role-name>/<session-name>`), not the plain IAM role ARN. A `ClusterRoleBinding` subject of `kind: User, name: <plain-role-arn>` will never match this, resulting in `... is forbidden ...` errors even though the IAM role and the binding both look correct.

**Fix:** Use `kubernetes_groups` on the `aws_eks_access_entry` resource, and bind the `ClusterRoleBinding`'s subject to that group (`kind: Group`) instead of trying to match the unpredictable session ARN string:

```hcl
resource "aws_eks_access_entry" "github_actions_plan" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = var.github_actions_plan_role_arn
  kubernetes_groups = ["github-actions-plan-readonly-group"]
}

resource "kubernetes_cluster_role_binding" "github_actions_plan_readonly" {
  # ...
  subject {
    kind      = "Group"
    name      = "github-actions-plan-readonly-group"
    api_group = "rbac.authorization.k8s.io"
  }
}
```

## See Also

- `argocd/README.md` — how the hub-and-spoke ArgoCD setup is wired into these environments, including the `selfHeal` lesson referenced above
- `k8s/README.md` — the Kubernetes manifests these environments ultimately run, including where image tags come from
- `.github/workflows/README.md` — the Terraform plan-on-PR pipeline that uses the OIDC roles documented above