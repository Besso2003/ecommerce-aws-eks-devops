variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs — used for security group ingress"
  type        = list(string)
}

variable "postgres_version" {
  type    = string
  default = "17.5"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Maximum storage in GB for autoscaling"
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "otel"
}

variable "db_username" {
  description = "Database master username"
  type        = string
  default     = "otel"
}

variable "multi_az" {
  description = "Enable Multi-AZ for high availability — true for prod"
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 0
}

variable "deletion_protection" {
  description = "Prevent accidental deletion — true for prod"
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on deletion — false for prod"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}