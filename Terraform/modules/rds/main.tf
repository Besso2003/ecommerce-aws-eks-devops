terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}


# Random Password — generated once, never appears in code
resource "random_password" "db_password" {
  length  = 32
  special = true
  # RDS doesn't allow these characters in passwords
  override_special = "!#$%&*()-_=+[]{}<>:?"
}


# Secrets Manager — stores the password securely
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${local.name_prefix}-rds-password"
  description             = "RDS master password for ${local.name_prefix}"
  recovery_window_in_days = 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
  })

  depends_on = [aws_db_instance.main]
}

# Security Group — only allow access from EKS nodes
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS postgres - allow access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL from EKS nodes"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-sg"
  })
}


# Subnet Group — RDS must be in private subnets
resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-rds-subnet-group"
  description = "RDS subnet group for ${local.name_prefix}"
  subnet_ids  = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-subnet-group"
  })
}


# Parameter Group — postgres tuning
resource "aws_db_parameter_group" "main" {
  name        = "${local.name_prefix}-rds-params"
  family      = "postgres17"
  description = "Parameter group for ${local.name_prefix} postgres"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-params"
  })
}


# RDS Instance
resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result # ← changed this line

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  parameter_group_name = aws_db_parameter_group.main.name

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name_prefix}-final-snapshot"

  performance_insights_enabled = var.multi_az

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-postgres"
  })
}