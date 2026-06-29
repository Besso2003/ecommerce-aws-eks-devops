output "state_bucket_name" {
  value = aws_s3_bucket.terraform_state.id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.terraform_locks.name
}

output "github_actions_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC to push images to ECR"
  value       = aws_iam_role.github_actions_ecr_push.arn
}

output "github_actions_terraform_plan_role_arn" {
  description = "IAM role ARN GitHub Actions assumes via OIDC to run terraform plan"
  value       = aws_iam_role.github_actions_terraform_plan.arn
}