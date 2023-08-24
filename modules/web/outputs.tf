output "s3_bucket_name" {
  description = "The name of the S3 bucket"
  value       = aws_s3_bucket.aws_s3_bucket_web.bucket
}

output "secretsmanager_secret_id" {
  description = "The ID of the Secrets Manager secret"
  value       = aws_secretsmanager_secret.this.name
}

output "ecr_repository_url" {
  description = "The ECR repository URL"
  value       = module.ecr.repository_url
}
