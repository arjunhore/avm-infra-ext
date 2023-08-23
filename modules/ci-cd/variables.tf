variable "region" {
  description = "AWS region used to provision resources (i.e. us-east-1/us-west-1)"
  type        = string
}

variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
}

variable "s3_bucket_name_webapp" {
  description = "The S3 bucket name for the webapp"
  type        = string
}

variable "secretsmanager_secret_id_webapp" {
  description = "The Secrets Manager secret ID for the webapp"
  type        = string
}
