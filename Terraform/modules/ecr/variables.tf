variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "repositories" {
  description = "List of ECR repository names — only custom images, not official ones"
  type        = list(string)
  default = [
    "ad-service",
    "product-catalog",
    "recommendation-service",
    "frontend",
    "frontend-proxy",
    "cart",
    "checkout",
    "currency",
    "email",
    "payment",
    "shipping",
    "fraud-detection",
    "accounting",
    "product-reviews",
    "quote",
    "image-provider",
    "load-generator",
    "flagd-ui",
    "llm"
  ]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}