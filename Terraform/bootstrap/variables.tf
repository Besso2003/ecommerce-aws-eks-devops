variable "aws_region" {
  type = string
  default = "eu-north-1"
}

variable "aws_profile" {
  type = string
}

variable "state_bucket_name" {
  type = string
}

variable "dynamodb_table_name" {
  type = string
  default = "ecommerce-terraform-locks"
}