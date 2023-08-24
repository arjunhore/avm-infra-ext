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

variable "secretsmanager_secret_id_server" {
  description = "The Secrets Manager secret ID for the server"
  type        = string
}

variable "ecr_repository_url_webapp" {
  description = "The ECR repository URL for the webapp"
  type        = string
}

variable "ecr_repository_url_server" {
  description = "The ECR repository URL for the server"
  type        = string
}

variable "ecr_repository_image_tag" {
  description = "The ECR repository image tag"
  type        = string
  default     = "latest"
}

variable "ecs_cluster_name" {
  description = "The ECS cluster name"
  type        = string
}

variable "ecs_service_name_server" {
  description = "The ECS service name for the server"
  type        = string
}

variable "cloudfront_distribution_id_webapp" {
  description = "The CloudFront distribution ID for the webapp"
  type        = string
}

variable "aws_account_id_root" {
  description = "The AWS root account ID"
  type        = string
  default     = "309847704252"
}
