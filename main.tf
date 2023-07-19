provider "aws" {
  region = local.region

  assume_role {
    role_arn = var.workspace_iam_roles[terraform.workspace]
  }
}

locals {
  region      = var.region
  namespace   = "avm-${terraform.workspace}-${var.environment}"
  environment = var.environment
  account_id  = data.aws_caller_identity.current.account_id

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_caller_identity" "current" {}
