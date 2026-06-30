terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# GitHub Actions OIDC — lets GitHub Actions assume an AWS IAM role with
# no stored AWS credentials at all. Trust is scoped to this exact repo
# and the main branch only.

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_actions_ecr_push" {
  name = "github-actions-ecr-push"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:Besso2003/ecommerce-source-code:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "github_actions_ecr_push" {
  name = "github-actions-ecr-push-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPushDevRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = [
          "arn:aws:ecr:eu-north-1:*:repository/ecommerce-dev/*",
          "arn:aws:ecr:eu-north-1:*:repository/ecommerce-prod/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr_push" {
  role       = aws_iam_role.github_actions_ecr_push.name
  policy_arn = aws_iam_policy.github_actions_ecr_push.arn
}


# GitHub Actions OIDC — Terraform plan-on-PR
# Read-only across the account. Used ONLY to run "terraform plan"
# automatically on pull requests. Cannot create, modify, or delete
# anything.

resource "aws_iam_role" "github_actions_terraform_plan" {
  name = "github-actions-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:Besso2003/ecommerce-aws-eks-devops:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan_readonly" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}