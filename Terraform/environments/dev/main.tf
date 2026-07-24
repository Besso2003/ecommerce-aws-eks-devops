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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
      args = concat(
        ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region],
        var.aws_profile != "" ? ["--profile", var.aws_profile] : []
      )
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = concat(
      ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region],
      var.aws_profile != "" ? ["--profile", var.aws_profile] : []
    )
  }
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "vpc" {
  source             = "../../modules/vpc"
  project_name       = var.project_name
  environment        = var.environment
  tags               = local.common_tags
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = true
  aws_region         = var.aws_region
}

module "iam" {
  source       = "../../modules/iam"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "eks" {
  source                       = "../../modules/eks"
  project_name                 = var.project_name
  environment                  = var.environment
  tags                         = local.common_tags
  kubernetes_version           = var.kubernetes_version
  eks_cluster_role_arn         = module.iam.eks_cluster_role_arn
  eks_node_role_arn            = module.iam.eks_node_role_arn
  public_subnet_ids            = module.vpc.public_subnet_ids
  private_subnet_ids           = module.vpc.private_subnet_ids
  node_instance_type           = var.node_instance_type
  node_desired_size            = var.node_desired_size
  node_min_size                = var.node_min_size
  node_max_size                = var.node_max_size
  aws_region                   = var.aws_region
  github_actions_plan_role_arn = "arn:aws:iam::707938860152:role/github-actions-terraform-plan"
}

module "ecr" {
  source       = "../../modules/ecr"
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
  aws_region   = var.aws_region
}

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
  type       = "kubernetes.io/service-account-token"
  depends_on = [kubernetes_service_account.argocd_manager]
}

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

resource "kubernetes_secret" "argocd_register_dev" {
  provider = kubernetes.hub
  metadata {
    name      = "dev-cluster-secret"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }
  type = "Opaque"
  data = {
    name   = "dev"
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

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [module.eks]
}

##############################################################################
# S3 buckets for observability storage (survive cluster recreation)
##############################################################################

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "loki" {
  bucket        = "ecommerce-dev-loki-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "loki" {
  bucket = aws_s3_bucket.loki.id
  versioning_configuration { status = "Suspended" }
}

resource "aws_s3_bucket" "tempo" {
  bucket        = "ecommerce-dev-tempo-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  versioning_configuration { status = "Suspended" }
}

##############################################################################
# IAM role for Loki via Pod Identity
##############################################################################

resource "aws_iam_role" "loki" {
  name = "ecommerce-dev-loki-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_policy" "loki" {
  name = "ecommerce-dev-loki-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.loki.arn,
        "${aws_s3_bucket.loki.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "loki" {
  role       = aws_iam_role.loki.name
  policy_arn = aws_iam_policy.loki.arn
}

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "loki"
  role_arn        = aws_iam_role.loki.arn
  depends_on      = [module.eks]
}

##############################################################################
# IAM role for Tempo via IRSA
# (Pod Identity not supported by Tempo 2.5.0's vendored AWS Go SDK —
#  IRSA uses AWS_WEB_IDENTITY_TOKEN_FILE which all SDK versions support)
##############################################################################

data "tls_certificate" "eks" {
  url = "https://oidc.eks.eu-north-1.amazonaws.com/id/44EB9822A1712D4598C864DD43DA3DFE"
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = "https://oidc.eks.eu-north-1.amazonaws.com/id/44EB9822A1712D4598C864DD43DA3DFE"
}

resource "aws_iam_policy" "tempo" {
  name = "ecommerce-dev-tempo-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ]
      Resource = [
        aws_s3_bucket.tempo.arn,
        "${aws_s3_bucket.tempo.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role" "tempo_irsa" {
  name = "ecommerce-dev-tempo-irsa-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "oidc.eks.eu-north-1.amazonaws.com/id/44EB9822A1712D4598C864DD43DA3DFE:sub" = "system:serviceaccount:monitoring:tempo"
          "oidc.eks.eu-north-1.amazonaws.com/id/44EB9822A1712D4598C864DD43DA3DFE:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "tempo_irsa" {
  role       = aws_iam_role.tempo_irsa.name
  policy_arn = aws_iam_policy.tempo.arn
}

##############################################################################
# Helm releases — observability stack
##############################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "61.3.0"
  namespace        = "monitoring"
  create_namespace = false

  values = [<<-EOT
    grafana:
      enabled: false
    prometheus:
      prometheusSpec:
        retention: 15d
        enableFeatures:
          - otlp-write-receiver
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: ebs-gp3
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 10Gi
        enableRemoteWriteReceiver: true
    alertmanager:
      alertmanagerSpec:
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: ebs-gp3
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 2Gi
  EOT
  ]
  depends_on = [kubernetes_namespace.monitoring]
}

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = "6.7.3"
  namespace        = "monitoring"
  create_namespace = false

  values = [<<-EOT
    deploymentMode: SingleBinary
    loki:
      auth_enabled: false
      commonConfig:
        replication_factor: 1
      storage:
        type: s3
        s3:
          region: eu-north-1
        bucketNames:
          chunks: ${aws_s3_bucket.loki.id}
          ruler: ${aws_s3_bucket.loki.id}
          admin: ${aws_s3_bucket.loki.id}
      schemaConfig:
        configs:
          - from: "2024-01-01"
            store: tsdb
            object_store: s3
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
    singleBinary:
      replicas: 1
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ""
    read:
      replicas: 0
    write:
      replicas: 0
    backend:
      replicas: 0
    gateway:
      enabled: false
    test:
      enabled: false
    lokiCanary:
      enabled: false
    chunksCache:
      enabled: false
    resultsCache:
      enabled: false
  EOT
  ]
  depends_on = [kubernetes_namespace.monitoring, aws_eks_pod_identity_association.loki]
}

resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  version          = "1.10.3"
  namespace        = "monitoring"
  create_namespace = false

  values = [<<-EOT
    tempo:
      metricsGenerator:
        enabled: true
        remoteWriteUrl: "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
      storage:
        trace:
          backend: s3
          s3:
            bucket: ${aws_s3_bucket.tempo.id}
            region: eu-north-1
            endpoint: s3.eu-north-1.amazonaws.com
            insecure: false
          wal:
            path: /var/tempo/wal
      reportingEnabled: false
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: "${aws_iam_role.tempo_irsa.arn}"
    persistence:
      enabled: false
    service:
      type: ClusterIP
  EOT
  ]
  depends_on = [kubernetes_namespace.monitoring, aws_iam_role_policy_attachment.tempo_irsa]
}