output "repository_urls" {
  description = "Map of repository name to URL — use these in your CI/CD pipeline"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of repository name to ARN"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}

output "registry_url" {
  description = "ECR registry base URL — account_id.dkr.ecr.region.amazonaws.com"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}