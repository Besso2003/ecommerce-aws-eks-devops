terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  tags               = local.common_tags
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = false
  aws_region         = var.aws_region
}

module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  project_name         = var.project_name
  environment          = var.environment
  tags                 = local.common_tags
  kubernetes_version   = var.kubernetes_version
  eks_cluster_role_arn = module.iam.eks_cluster_role_arn
  eks_node_role_arn    = module.iam.eks_node_role_arn
  public_subnet_ids    = module.vpc.public_subnet_ids
  private_subnet_ids   = module.vpc.private_subnet_ids
  node_instance_type   = var.node_instance_type
  node_desired_size    = var.node_desired_size
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  aws_region           = var.aws_region
}

module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
  aws_region   = var.aws_region
}

module "rds" {
  source                = "../../modules/rds"
  project_name          = var.project_name
  environment           = var.environment
  tags                  = local.common_tags
  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnet_ids
  private_subnet_cidrs  = module.vpc.private_subnet_cidrs
  instance_class        = var.rds_instance_class
  multi_az              = false
  deletion_protection   = false
  skip_final_snapshot   = true
  backup_retention_days = 0
}

# External Secrets Operator — installed via Helm through Terraform
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }

  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = kubernetes_namespace.external_secrets.metadata[0].name
  create_namespace = false

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks.external_secrets_role_arn
  }

  depends_on = [kubernetes_namespace.external_secrets]
}

# ServiceAccount for the HUB's ArgoCD to manage THIS cluster remotely
resource "kubernetes_service_account" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }

  depends_on = [module.eks]
}

resource "kubernetes_cluster_role_binding" "argocd_manager" {
  metadata {
    name = "argocd-manager-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argocd_manager.metadata[0].name
    namespace = kubernetes_service_account.argocd_manager.metadata[0].namespace
  }
}

resource "kubernetes_secret" "argocd_manager_token" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.argocd_manager.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account.argocd_manager]
}

# Second kubernetes provider — points at the HUB cluster, not prod's own
data "aws_eks_cluster" "hub" {
  name = "ecommerce-platform-cluster"
}

data "aws_eks_cluster_auth" "hub" {
  name = "ecommerce-platform-cluster"
}

provider "kubernetes" {
  alias                  = "hub"
  host                   = data.aws_eks_cluster.hub.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.hub.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.hub.token
}

# Register prod cluster with the HUB's ArgoCD
resource "kubernetes_secret" "argocd_register_prod" {
  provider = kubernetes.hub

  metadata {
    name      = "prod-cluster-secret"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  type = "Opaque"

  data = {
    name   = "prod"
    server = module.eks.cluster_endpoint
    config = jsonencode({
      tlsClientConfig = {
        insecure = false
        caData   = module.eks.cluster_ca_certificate
      }
      bearerToken = kubernetes_secret.argocd_manager_token.data["token"]
    })
  }

  depends_on = [kubernetes_secret.argocd_manager_token]
}