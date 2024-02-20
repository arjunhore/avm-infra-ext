terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.8"
    }
  }

  backend "s3" {
    bucket = "avm-terraform-backend-${local.account_id}"
    key    = "terraform/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  account_id          = data.aws_caller_identity.current.account_id
}
