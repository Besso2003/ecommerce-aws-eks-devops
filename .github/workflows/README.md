# GitHub Actions Workflows

This folder contains the CI automation for the infrastructure repo. There is one workflow here:

```
terraform-plan.yml   -- runs "terraform plan" automatically on every
                          Pull Request that touches Terraform/, for
                          all three environments (dev, prod, platform)
```

The app build/push pipeline (a separate workflow, covering the 16 microservices) lives in the **`ecommerce-source-code`** repo instead, since that's where the application code actually changes. See that repo's `.github/workflows/README.md` for its documentation.

## What `terraform-plan.yml` does

```
1. Triggers on any Pull Request that changes a file under Terraform/
2. Runs a matrix job: one parallel run each for dev, prod, and platform
3. Each run, in its own environment folder:
     a. Authenticates to AWS via OIDC (no stored credentials)
     b. Runs terraform init
     c. Runs terraform plan
     d. Posts the full plan output as a comment on the PR, clearly
        labeled by environment
4. terraform apply is NEVER run by this workflow. Applying changes
   stays a deliberate, manual step, run locally after reviewing the
   plan output - exactly the same human-gated safety boundary that
   Terraform Cloud and Atlantis use by default.
```

You'll see three separate comments on any PR that touches `Terraform/`, one per environment, each showing exactly what would change if you ran `terraform apply` in that environment right now.

## Why plan is read-only, and what that actually means

The workflow authenticates using a dedicated IAM role (`github-actions-terraform-plan`, provisioned in `Terraform/bootstrap/main.tf`) that is deliberately scoped to be incapable of changing anything:

```
AWS side:   AWS-managed "ReadOnlyAccess" policy - can describe/read
             almost everything, can create/modify/delete nothing

Kubernetes
side:        A dedicated read-only ClusterRole (get, list, watch only -
             no create/update/patch/delete) bound to this role via an
             EKS Access Entry, on every cluster (dev, prod, platform)
```

This second part exists because some resources in each environment's `main.tf` are Kubernetes objects, not AWS objects (the `argocd-manager` ServiceAccount, its RBAC binding, the ArgoCD cluster-registration Secret, and the External Secrets Helm release). `terraform plan` needs to read the *current state* of these too, which means it needs real (if read-only) access into the actual running cluster - not just AWS's metadata about the cluster.

## Known gotchas already solved here, so you don't have to re-debug them

- **State locking**: `terraform plan` normally needs `dynamodb:PutItem` to acquire a state lock before it can even read anything. The read-only role doesn't have that permission. The workflow passes `-lock=false`, which is safe here specifically because this role can never run `apply` - there's nothing to protect against concurrent writes.
- **AWS profile**: every environment's `provider "aws"` and `exec` blocks default to a personal CLI profile (`var.aws_profile`, default `"bassant"`) that doesn't exist on GitHub's runners. The workflow passes `-var="aws_profile="` to override it to empty, which makes both the AWS provider and the `aws eks get-token` calls fall back to the OIDC-issued credentials already present as environment variables. Each environment's `main.tf` wraps the `--profile` flag in a `concat(...)` so it's only added when `aws_profile` is non-empty - this means your own local `terraform apply` runs are completely unaffected, since your local default is still `"bassant"`.
- **IAM role vs IAM user RBAC subjects**: when an IAM *role* authenticates to an EKS cluster (as opposed to an IAM *user*), Kubernetes sees the STS *assumed-role session* identity, not the plain role ARN - so a `ClusterRoleBinding` with `subject.kind = "User"` and the role's ARN as the name will never match. The fix used here is `kubernetes_groups` on the `aws_eks_access_entry`, with the `ClusterRoleBinding` targeting that group (`subject.kind = "Group"`) instead of trying to match an unpredictable session ARN string.

## A real lesson learned, worth repeating here too

During setup, a `ClusterSecretStore` fix was applied directly to a live cluster with `kubectl apply` and appeared to work, only to silently revert minutes later. The cause: ArgoCD's `selfHeal` detected the live cluster drifting from what was committed in git, and "healed" it back to the old, broken config. **Any fix to a resource ArgoCD manages must be committed and pushed - never applied directly to a cluster** - or it will not persist. See `argocd/README.md` for the fuller writeup of this.

## Known limitation, by design (not a bug)

`terraform apply` is manual for all three environments - including `dev`. Tiered automation (auto-apply for low-stakes environments, manual for production) is a legitimate, common pattern at many companies, and was deliberately considered here. It was not adopted yet because this project's Terraform has a real, demonstrated history of needing human judgment mid-operation - recurring stuck VPC/Internet Gateway deletions caused by leftover Kubernetes-created ELBs, AWS vCPU quota limits, and Secrets Manager recovery-window conflicts have all required manual diagnosis and intervention during this project's actual usage, not just in theory. A `scripts/safe-destroy.sh` helper now automates detecting and clearing the ELB/security-group issue specifically (see the script's own header comment for how it works), which is a step toward making `apply`/`destroy` safe to run unattended - revisit auto-apply for `dev` once that and the other recurring issues are confidently handled without a human watching.

## Future enhancement (not built, intentionally deferred)

Right now, every PR that touches anything under `Terraform/` triggers a plan for **all three** environments, every time - even a one-line change to `dev/variables.tf` that obviously can't affect `prod`. The more rigorous version of this workflow would use dependency-aware detection (the way tools like Atlantis or Terragrunt's `run-all` do) to plan only the environments actually affected by a given change.

This wasn't built because, for this repo's specific module structure, the answer would always be the same either way: all three environments share the same handful of modules (`vpc`, `iam`, `eks`, `ecr`, with `rds` used by `prod` only), so a dependency-aware system would compute "plan all three" for nearly every real change anyway. Building the machinery to derive that answer dynamically would add real complexity for no behavioral difference at this repo's current scale. Worth revisiting if the module structure ever diverges meaningfully between environments, or if a fourth environment is added that doesn't share every module.