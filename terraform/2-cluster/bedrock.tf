#######################################
# Amazon Bedrock
#######################################
#
# Amazon Bedrock foundation model access with:
# - Model invocation logging to CloudWatch Logs
# - Access from ROSA via IRSA (roles in oidc.tf)
#
# Note: Actual model access is granted via AWS Console or CLI.
#######################################

# CloudWatch Log Group for Bedrock Model Invocation Logs
resource "aws_cloudwatch_log_group" "bedrock_logs" {
  count = var.enable_bedrock_logging ? 1 : 0

  name              = "/${var.org_moniker}/${var.client}/${var.environment}/bedrock/model-invocations"
  retention_in_days = var.cloudwatch_log_retention_days
  kms_key_id        = data.terraform_remote_state.foundation.outputs.workload_kms_key_arn

  tags = {
    Name    = "log-${module.ctx.id}-bedrock"
    Purpose = "bedrock-model-invocation-logs"
  }
}

# IAM Role for Bedrock to Write to CloudWatch Logs
resource "aws_iam_role" "bedrock_logging" {
  count = var.enable_bedrock_logging ? 1 : 0

  name = "role-${module.ctx.id}-bedrock-logging"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "role-${module.ctx.id}-bedrock-logging"
  }
}

# IAM Policy for Bedrock Logging Role
resource "aws_iam_role_policy" "bedrock_logging" {
  count = var.enable_bedrock_logging ? 1 : 0

  name = "policy-${module.ctx.id}-bedrock-logging"
  role = aws_iam_role.bedrock_logging[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.bedrock_logs[0].arn}:log-stream:aws/bedrock/modelinvocations"
      }
    ]
  })
}

# Bedrock Model Invocation Logging Configuration
resource "aws_bedrock_model_invocation_logging_configuration" "main" {
  count = var.enable_bedrock_logging ? 1 : 0

  logging_config {
    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_logs[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn
    }

    text_data_delivery_enabled = true
  }

  depends_on = [
    aws_cloudwatch_log_group.bedrock_logs,
    aws_iam_role.bedrock_logging
  ]
}
