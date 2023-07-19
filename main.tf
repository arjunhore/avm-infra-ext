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

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "${local.namespace}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}
