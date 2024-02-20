output "target_group_id" {
  description = "ID that identifies the ALB target group"
  value       = aws_alb_target_group.this.id
}

output "target_group_arn" {
  description = "ARN that identifies the ALB target group"
  value       = aws_alb_target_group.this.arn
}

output "secretsmanager_secret_id" {
  description = "The ID of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.this.name
}

output "ecr_repository_url" {
  description = "The ECR repository URL"
  value       = module.ecr.repository_url
}

output "ecs_service_name" {
  description = "The ECS service name"
  value       = aws_ecs_service.this.name
}

output "api_key" {
  description = "The is the API Key used for the CURL command"
  value = jsondecode(aws_secretsmanager_secret_version.this.secret_string)["API_KEY"]
}

output "account_id" {
  value = local.account_id
}