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

variable "workspace_iam_roles" {
  default = {
    mcro = "arn:aws:iam::670255240370:role/AVMAdminRole"
  }
}
