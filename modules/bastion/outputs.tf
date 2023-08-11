output "public_ip" {
  description = "The public IP address of the bastion host"
  value       = module.bastion.public_ip
}
