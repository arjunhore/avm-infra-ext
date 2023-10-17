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

variable "root_domain_name" {
  description = "The root domain name"
  type        = string
  default     = "avm.technology"
}

variable "notifications_email" {
  description = "The email address for notifications"
  type        = string
  default     = "support@addvaluemachine.com"
}

variable "rds_master_username" {
  type        = string
  description = "The master username for the RDS instance"
  default     = "postgres"
}

variable "rds_master_password" {
  type        = string
  description = "The master password for the RDS instance"
  default     = ""
}

variable "rds_database_name" {
  type        = string
  description = "The database name for the RDS instance"
  default     = "avmserver"
}

variable "rds_port" {
  type        = number
  description = "The RDS instance port"
  default     = 5432
}

variable "redis_port" {
  type        = number
  description = "The Redis instance port"
  default     = 6379
}

variable "statistic_period" {
  description = "The number of seconds that make each statistic period."
  type        = number
  default     = 60
}

variable "rds_cpu_usage_threshold" {
  description = "The maximum percentage of CPU utilization."
  type        = number
  default     = 80
}

variable "rds_local_storage_threshold" {
  description = "The amount of local storage available."
  type        = number
  default     = 1024 * 1000 * 1000 # 1 GB
}

variable "rds_freeable_memory_threshold" {
  description = "The amount of available random access memory."
  type        = number
  default     = 256 * 1000 * 1000 # 256 MB
}

variable "rds_disk_queue_depth_threshold" {
  description = "The number of outstanding read/write requests waiting to access the disk."
  type        = number
  default     = 64
}

variable "alb_unhealthy_hosts_threshold" {
  description = "The number of unhealthy hosts."
  type        = number
  default     = 0
}

variable "alb_response_time_threshold" {
  description = "The average number of milliseconds that requests should complete within."
  type        = number
  default     = 1000
}

variable "alb_5xx_response_threshold" {
  description = "The number of 5xx responses."
  type        = number
  default     = 0
}

variable "aws_account_id_root" {
  description = "The AWS root account ID"
  type        = string
  default     = "309847704252"
}

variable "workspace_iam_roles" {
  default = {
    renaissance          = "arn:aws:iam::624134621134:role/AVMAdminRole"
    gap                  = "arn:aws:iam::106421789552:role/AVMAdminRole"
    firebirds            = "arn:aws:iam::181755216119:role/AVMAdminRole"
    incyte               = "arn:aws:iam::628335480986:role/AVMAdminRole"
    adcb                 = "arn:aws:iam::226270385471:role/AVMAdminRole"
    addvaluemachine-demo = "arn:aws:iam::725002219993:role/AVMAdminRole"
    addvaluemachine      = "arn:aws:iam::902610975495:role/AVMAdminRole"
  }
}
