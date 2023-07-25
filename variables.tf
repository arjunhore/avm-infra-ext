variable "region" {
  description = "AWS region used to provision resources (i.e. us-east-1/us-west-1)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
  default     = "prod"
}

variable "domain_name" {
  description = "The root domain name"
  type        = string
  default     = "avm.technology"
}

variable "ecr_repository_image" {
  description = "The ECR repository URI for the server image"
  type        = string
  default     = "309847704252.dkr.ecr.us-east-1.amazonaws.com/avm-server:1.0.0"
}

variable "rds_master_password" {
  type        = string
  description = "The master password for the RDS instance"
  default     = "YpRPU*38N13K6z9ik163&8Tp*"
}

variable "workspace_iam_roles" {
  default = {
    mcro = "arn:aws:iam::670255240370:role/AVMAdminRole"
  }
}
