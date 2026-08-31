#######################################
# Data-Service Credentials (AWS Secrets Manager)
#######################################
#
# Source of truth for in-cluster data-service credentials. External
# Secrets Operator (gitops/components/platform/external-secrets)
# syncs these into the cluster via the IRSA role from the cluster
# stack. PostgreSQL needs no secret here: the Zalando operator
# generates per-user credentials in-cluster itself.
#
# No secret material touches Terraform state: passwords are ephemeral
# (never persisted) and written through write-only arguments. The
# secret value only changes when var.secrets_rotation_version is
# bumped — bump it to rotate.
#
# Secret naming contract with gitops: hello-openshift/{env}/{service}
#
#######################################

ephemeral "random_password" "redis" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "redis" {
  name        = "hello-openshift/${var.environment}/redis"
  description = "Redis auth for ${module.ctx.id}"

  kms_key_id              = aws_kms_key.workload.arn
  recovery_window_in_days = var.secrets_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id
  secret_string_wo = jsonencode({
    password = ephemeral.random_password.redis.result
  })
  secret_string_wo_version = var.secrets_rotation_version
}

ephemeral "random_password" "minio_root" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "minio" {
  name        = "hello-openshift/${var.environment}/minio"
  description = "MinIO root credentials for ${module.ctx.id}"

  kms_key_id              = aws_kms_key.workload.arn
  recovery_window_in_days = var.secrets_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "minio" {
  secret_id = aws_secretsmanager_secret.minio.id
  secret_string_wo = jsonencode({
    root_user     = "minio-admin"
    root_password = ephemeral.random_password.minio_root.result
  })
  secret_string_wo_version = var.secrets_rotation_version
}
