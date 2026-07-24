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
  single_nat_gateway = true
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
  github_actions_plan_role_arn = "arn:aws:iam::707938860152:role/github-actions-terraform-plan"
}

# ArgoCD — the hub. This is the ONLY cluster that runs ArgoCD.
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false

  depends_on = [kubernetes_namespace.argocd]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
  depends_on = [module.eks]
}

resource "helm_release" "grafana" {
  name             = "grafana"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = "8.3.6"
  namespace        = "monitoring"
  create_namespace = false

  values = [<<-EOT
    adminPassword: "admin123"
    persistence:
      enabled: true
      storageClassName: ebs-gp3
      size: 5Gi
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-internal: "true"
    datasources:
      datasources.yaml:
        apiVersion: 1
        datasources:
          - name: Prometheus (dev)
            type: prometheus
            uid: prometheus-dev
            url: http://internal-ab215d4de7d81482598119848418e536-273134346.eu-north-1.elb.amazonaws.com:9090
            access: proxy
            isDefault: true
          - name: Loki (dev)
            type: loki
            url: http://internal-ac22491bba0f84b2088c22e81919610b-730837534.eu-north-1.elb.amazonaws.com:3100
            access: proxy
          - name: Tempo (dev)
            type: tempo
            url: http://internal-ab8f8df20456e4eada6fb63e14cf857e-975497401.eu-north-1.elb.amazonaws.com:3100
            access: proxy
            jsonData:
              serviceMap:
                datasourceUid: prometheus-dev
    dashboardProviders:
      dashboardproviders.yaml:
        apiVersion: 1
        providers:
          - name: default
            folder: Kubernetes
            type: file
            options:
              path: /var/lib/grafana/dashboards/default
    dashboards:
      default:
        kubernetes-cluster:
          gnetId: 315
          revision: 3
          datasource: Prometheus (dev)
        kubernetes-pods:
          gnetId: 747
          revision: 2
          datasource: Prometheus (dev)
        node-exporter:
          gnetId: 1860
          revision: 37
          datasource: Prometheus (dev)
  EOT
  ]

  depends_on = [kubernetes_namespace.monitoring]
}