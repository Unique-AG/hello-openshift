#######################################
# ROSA HCP Cluster
#######################################
#
# Creates a ROSA (Red Hat OpenShift Service on AWS) cluster
# with Hosted Control Plane for reduced infrastructure costs.
#
# The cluster is deployed in private mode by default.
#
#######################################

# ROSA HCP Cluster
resource "rhcs_cluster_rosa_hcp" "cluster" {
  count = var.rosa_type == "hcp" ? 1 : 0

  name                   = local.cluster_name
  cloud_region           = var.aws_region
  aws_account_id         = var.aws_account_id
  aws_billing_account_id = var.aws_account_id

  # OpenShift version
  version = local.rosa_version

  # Network configuration
  aws_subnet_ids     = local.private_subnet_ids
  availability_zones = local.azs

  # Private cluster settings
  private = var.private_cluster

  # STS configuration
  sts = {
    oidc_config_id       = rhcs_rosa_oidc_config.oidc[0].id
    operator_role_prefix = local.operator_role_prefix
    role_arn             = local.installer_role_arn
    support_role_arn     = local.support_role_arn
    instance_iam_roles = {
      worker_role_arn = local.worker_role_arn
    }
  }

  # Encryption
  etcd_encryption  = var.etcd_encryption
  etcd_kms_key_arn = var.etcd_encryption ? aws_kms_key.etcd[0].arn : null

  # Properties
  properties = {
    rosa_creator_arn = data.aws_caller_identity.current.arn
  }

  # Wait for the cluster to be ready
  wait_for_create_complete = true

  depends_on = [
    module.operator_roles,
    module.account_roles,
    aws_vpc.main,
    aws_subnet.private,
    aws_route_table_association.private
  ]
}

#######################################
# CloudWatch Logging
#######################################

resource "aws_cloudwatch_log_group" "rosa" {
  count = var.enable_cluster_logging ? 1 : 0

  name              = "/rosa/${local.cluster_name}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Name = "logs-${local.cluster_name}"
  }
}

#######################################
# Wait for Cluster Ready
#######################################

resource "time_sleep" "wait_for_cluster" {
  count = var.rosa_type == "hcp" ? 1 : 0

  depends_on = [rhcs_cluster_rosa_hcp.cluster]

  create_duration = "30s"
}
