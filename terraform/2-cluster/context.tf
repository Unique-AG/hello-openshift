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
  stack       = "cluster"

  aws_account_id   = var.aws_account_id
  aws_region       = var.aws_region
  semantic_version = var.semantic_version
  extra_tags       = var.additional_tags
}

locals {
  # Cluster name: rosa-{org_moniker}-{client}-{environment}
  cluster_name = var.cluster_name != null ? var.cluster_name : "rosa-${var.org_moniker}-${var.client}-${var.environment}"

  # Availability zones
  azs = var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, var.multi_az ? 3 : 1)

  # Operator role prefix for ROSA
  operator_role_prefix = "${local.cluster_name}-operator"
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}
