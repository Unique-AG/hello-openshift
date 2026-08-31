#######################################
# IAM Policies
#######################################

resource "aws_iam_policy" "terraform_state_access" {
  count = var.use_oidc && var.github_repository != "" ? 1 : 0

  name        = "${module.ctx.iam_policy_prefix}-tfstate-access"
  description = "Policy for Terraform state access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = var.enable_server_side_encryption ? [aws_kms_key.terraform_state[0].arn] : []
      }
    ]
  })

  tags = local.tags
}
