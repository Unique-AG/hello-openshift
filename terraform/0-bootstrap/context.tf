#######################################
# Stack Context
#######################################
#
# Naming, tagging, and shared locals for the bootstrap stack.
# Resources here keep explicit `tags = merge(local.tags, ...)` (instead
# of provider default_tags) so the restructure stays a no-op plan
# against the pre-existing bootstrap state.
#
#######################################

module "ctx" {
  source = "../modules/stack-context"

  org         = var.org
  org_moniker = var.org_moniker
  client      = var.client
  client_name = var.client_name
  environment = var.environment
  stack       = "bootstrap"

  aws_account_id   = var.aws_account_id
  aws_region       = var.aws_region
  semantic_version = var.semantic_version
}

locals {
  # S3 bucket name using module's s3_bucket_prefix
  # Format: s3-{id_short}-tfstate
  s3_bucket_name = "${module.ctx.s3_bucket_prefix}-tfstate"

  # KMS key alias with resource moniker, environment, and region
  # Format: alias/kms-{id}-tfstate
  kms_key_alias = "alias/kms-${module.ctx.id}-tfstate"

  # IAM role name for GitHub Actions using module's iam_role_prefix
  github_actions_role_name = "${module.ctx.iam_role_prefix}-github-actions"

  tags = module.ctx.tags
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# GitHub Actions OIDC
locals {
  gha_enabled = var.use_oidc && var.github_repository != ""

  # Default to the deploy branch alone. This role can write Terraform state and
  # use the state KMS key, so the trust policy must not accept every ref in the
  # repository.
  gha_subjects = length(var.github_actions_subjects) > 0 ? var.github_actions_subjects : [
    "repo:${var.github_repository}:ref:refs/heads/deploy",
  ]
}
