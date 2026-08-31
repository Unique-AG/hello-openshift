#######################################
# CloudWatch Log Group
#######################################

resource "aws_cloudwatch_log_group" "terraform" {
  name              = "/terraform/${module.ctx.id}"
  retention_in_days = var.cloudwatch_log_retention_days
  kms_key_id        = var.enable_server_side_encryption ? aws_kms_key.terraform_state[0].arn : null

  tags = merge(
    local.tags,
    {
      Name        = "logs-${module.ctx.id}-terraform"
      Description = "CloudWatch logs for Terraform operations"
    }
  )
}
