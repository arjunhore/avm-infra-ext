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
  description = "The root domain name. Example: avm.technology"
  type        = string
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

variable "container_registry_username" {
  description = "The GitHub Container registry username"
  type        = string
  default     = "addvaluemachine"
  sensitive   = true
}

variable "container_registry_token" {
  description = "The GitHub Container registry token"
  type        = string
  sensitive   = true
}
