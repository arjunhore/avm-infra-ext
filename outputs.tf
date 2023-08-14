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

output "bastion_ip" {
  description = "The public IP address of the bastion host"
  value       = module.bastion.public_ip
}

output "vanta_auditor_arn" {
  description = "The arn from the Terraform created role that you need to input into the Vanta UI at the end of the AWS connection steps."
  value       = module.vanta[0].vanta_auditor_arn
}
