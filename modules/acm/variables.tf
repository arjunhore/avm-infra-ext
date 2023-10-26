variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
}

variable "root_domain_name" {
  description = "The domain name"
  type        = string
}

variable "route53_zone_id" {
  description = "The Route53 zone ID"
  type        = string
}
