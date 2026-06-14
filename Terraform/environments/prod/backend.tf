terraform {
  backend "s3" {
    bucket         = "ecommerce-tf-state-bassant"
    key            = "prod/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "ecommerce-terraform-locks-bassant"
    encrypt        = true
  }
}