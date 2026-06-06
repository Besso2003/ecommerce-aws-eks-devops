output "state_bucket_name" {
  description = "S3 bucket name — paste into each environment backend.tf"
  value       = aws_s3_bucket.terraform_state.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table name — paste into each environment backend.tf"
  value       = aws_dynamodb_table.terraform_locks.name
}