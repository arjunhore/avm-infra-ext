output "rds_cluster_endpoint" {
  description = "Writer endpoint for the cluster"
  value       = module.cluster.cluster_endpoint
}

output "rds_database_name" {
  description = "Name for an automatically created database on cluster creation"
  value       = module.cluster.cluster_database_name
}

output "rds_port" {
  description = "The database port"
  value       = module.cluster.cluster_port
}

output "rds_master_username" {
  description = "The database master username"
  value       = nonsensitive(module.cluster.cluster_master_username)
}

output "rds_master_password" {
  description = "The database master password"
  value       = nonsensitive(module.cluster.cluster_master_password)
}

output "api_key" {
  description = "The is the API Key used for the CURL command"
  value = nonsensitive(module.server.api_key)
}