#######################################
# Outputs
#######################################
#
# Output contract consumed by the 2-cluster stack via
# terraform_remote_state (see terraform/2-cluster/remote-state.tf).
#
#######################################

# KMS
output "workload_kms_key_arn" {
  description = "ARN of the workload KMS key"
  value       = aws_kms_key.workload.arn
}

output "workload_kms_key_alias" {
  description = "Alias of the workload KMS key"
  value       = aws_kms_alias.workload.name
}

# S3 Buckets
output "application_data_bucket_name" {
  description = "Name of the application data S3 bucket"
  value       = aws_s3_bucket.application_data.id
}

output "application_data_bucket_arn" {
  description = "ARN of the application data S3 bucket"
  value       = aws_s3_bucket.application_data.arn
}

output "ai_data_bucket_name" {
  description = "Name of the AI data S3 bucket"
  value       = aws_s3_bucket.ai_data.id
}

output "ai_data_bucket_arn" {
  description = "ARN of the AI data S3 bucket"
  value       = aws_s3_bucket.ai_data.arn
}

# Budget
output "budget_name" {
  description = "Name of the monthly cost budget"
  value       = aws_budgets_budget.monthly_budget.name
}

# Secrets
output "redis_secret_arn" {
  description = "ARN of the Redis credentials secret"
  value       = aws_secretsmanager_secret.redis.arn
}

output "minio_secret_arn" {
  description = "ARN of the MinIO credentials secret"
  value       = aws_secretsmanager_secret.minio.arn
}

output "secrets_prefix" {
  description = "Secrets Manager name prefix used by ExternalSecrets"
  value       = "hello-openshift/${var.environment}"
}
