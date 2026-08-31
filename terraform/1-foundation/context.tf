#######################################
# Stack Context
#######################################

module "ctx" {
  source = "../modules/stack-context"

  org         = var.org
  org_moniker = var.org_moniker
  client      = var.client
  client_name = var.client_name
  environment = var.environment
  stack       = "foundation"

  aws_account_id   = var.aws_account_id
  aws_region       = var.aws_region
  semantic_version = var.semantic_version
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
