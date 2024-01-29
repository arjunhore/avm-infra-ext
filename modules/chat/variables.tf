variable "region" {
  description = "AWS region used to provision resources (i.e. us-east-1/us-west-1)"
  type        = string
}

variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
}

variable "domain_name" {
  description = "The domain name"
  type        = string
}

variable "certificate_arn" {
  description = "The domain certificate ARN"
  type        = string
}

variable "route53_zone_id" {
  description = "The Route53 zone ID"
  type        = string
}

variable "web_acl_arn" {
  description = "If using WAFv2, provide the ARN of the web ACL."
  type        = string
}

variable "firebase_api_key" {
  description = "The firebase API key from Firebase app"
  type        = string
}

variable "firebase_auth_domain" {
  description = "The firebase Auth domain value from Firebase app"
  type        = string
}

variable "firebase_project_id" {
  description = "The firebase project id value from Firebase organisation"
  type        = string
}

variable "firebase_storage_bucket" {
  description = "The firebase storage bucket value from the Firebase app"
  type        = string
}

variable "firebase_messaging_sender_id" {
  description = "The firebase messaging sender id value from the Firebase app"
  type        = string
}

variable "firebase_app_id" {
  description = "The firebase app id value from the Firebase app"
  type        = string
}

variable "firebase_measurement_id" {
  description = "The firebase measurement id value from the Firebase app"
  type        = string
}
