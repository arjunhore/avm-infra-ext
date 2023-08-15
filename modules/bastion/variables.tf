variable "region" {
  description = "AWS region used to provision resources (i.e. us-east-1/us-west-1)"
  type        = string
}

variable "environment" {
  description = "Environment used for creating resources (will be appended to various resources)"
  type        = string
}

variable "vpc_id" {
  description = "The VPC ID"
  type        = string
}

variable "sns_topic_alerts_arn" {
  description = "The SNS topic ARN to send alerts to"
  type        = string
}

variable "ec2_bastion_ami_id" {
  type        = string
  description = "Amazon Linux AMI ID for the Bastion instance"
  default     = "ami-0a58b475e94715d02"
}

variable "ec2_cpu_usage_threshold" {
  description = "The maximum percentage of CPU utilization."
  type        = number
  default     = 90
}
