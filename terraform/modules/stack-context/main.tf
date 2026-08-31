#######################################
# Stack Context
#######################################
#
# Wraps the shared naming module and centralizes the tag merge so
# every stack derives names and tags the same way. Outputs feed
# provider default_tags, so they must resolve from variables alone:
# always pass aws_account_id and aws_region so the naming module's
# fallback data sources stay disabled (count = 0).
#
#######################################

module "naming" {
  source = "../naming"

  org         = var.org
  org_moniker = var.org_moniker
  client      = var.client
  layer       = var.stack
  environment = var.environment

  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region

  semantic_version = var.semantic_version
}
