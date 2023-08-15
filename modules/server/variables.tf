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

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "ecs_cluster_id" {
  description = "The ECS cluster ID"
  type        = string
}

variable "ecs_cluster_name" {
  description = "The ECS cluster name"
  type        = string
}

variable "load_balancer_security_group_id" {
  description = "The load balancer security group ID"
  type        = string
}

variable "ecr_repository_image" {
  description = "The ECR repository image URI"
  type        = string
}

variable "docker_container_port" {
  description = "The Docker container port number"
  type        = number
  default     = 3001
}

variable "autoscaling_min_instances" {
  description = "The minimum number of instances that should be running"
  type        = number
  default     = 1
}

variable "autoscaling_max_instances" {
  description = "The maximum number of instances that should be running"
  type        = number
  default     = 4
}

variable "autoscaling_cpu_low_threshold" {
  description = "Threshold for min CPU usage"
  type        = number
  default     = 20
}

variable "autoscaling_cpu_high_threshold" {
  description = "Threshold for max CPU usage"
  type        = number
  default     = 80
}

variable "route53_zone_id" {
  description = "The Route53 zone ID"
  type        = string
}

variable "web_acl_arn" {
  description = "If using WAFv2, provide the ARN of the web ACL."
  type        = string
}
