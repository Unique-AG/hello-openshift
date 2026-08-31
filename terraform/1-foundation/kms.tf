#######################################
# KMS Keys for Application Workloads
#######################################
#
# General-purpose KMS keys for workloads deployed on ROSA.
# Note: ROSA-specific KMS keys (e.g., etcd encryption) are in 05-compute.
#######################################

resource "aws_kms_key" "workload" {
  description             = "KMS key for workload encryption - ${module.ctx.id}"
  deletion_window_in_days = var.kms_deletion_window == 0 ? 7 : var.kms_deletion_window
  enable_key_rotation     = var.kms_enable_rotation

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs to use the key"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "kms-${module.ctx.id}-workload"
    Description = "KMS key for workload encryption"
  }
}

resource "aws_kms_alias" "workload" {
  name          = "alias/kms-${module.ctx.id}-workload"
  target_key_id = aws_kms_key.workload.key_id
}
