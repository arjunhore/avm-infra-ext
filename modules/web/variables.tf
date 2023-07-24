variable "region" {
  description = "AWS region used to provision resources (i.e. us-east-1/us-west-1)"
  type        = string
}

variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
}

variable "namespace" {
  description = "Namespace (up to 255 letters, numbers, hyphens, and underscores)"
  type        = string
}
