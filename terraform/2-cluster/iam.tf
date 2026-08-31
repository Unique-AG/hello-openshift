#######################################
# IAM Roles for ROSA Cluster (STS Mode)
#######################################
#
# ROSA with STS (Secure Token Service) requires several IAM roles:
# - Account Roles: Installer, Support, Worker, Control Plane
# - Operator Roles: Created per-cluster for various operators
#
# These roles use short-lived credentials via OIDC federation.
#
#######################################

data "rhcs_versions" "all" {}

locals {
  # Find the latest version matching our specified version prefix
  rosa_version = [for v in data.rhcs_versions.all.items : v.name if startswith(v.name, var.openshift_version)][0]
}

#######################################
# Account Roles (official Red Hat module)
#######################################
#
# OCM strictly validates HCP account roles (AWS managed ROSA policies,
# classification tags, canonical -HCP-ROSA-*-Role names, SRE support
# principal). The official module produces exactly that shape and
# waits for IAM propagation itself.
#
module "account_roles" {
  source  = "terraform-redhat/rosa-hcp/rhcs//modules/account-iam-resources"
  version = "~> 1.7"

  account_role_prefix = local.cluster_name
  tags                = module.ctx.tags
}

locals {
  installer_role_arn = module.account_roles.account_roles_arn["HCP-ROSA-Installer"]
  support_role_arn   = module.account_roles.account_roles_arn["HCP-ROSA-Support"]
  worker_role_arn    = module.account_roles.account_roles_arn["HCP-ROSA-Worker"]
}

#######################################
# KMS Key for etcd Encryption
#######################################

resource "aws_kms_key" "etcd" {
  count = var.etcd_encryption ? 1 : 0

  description             = "KMS key for ROSA etcd encryption - ${local.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow ROSA to use the key"
        Effect = "Allow"
        Principal = {
          AWS = local.installer_role_arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        # etcd encryption at runtime happens via the kms-provider
        # operator role; without this the control plane stalls with
        # kms:Encrypt AccessDenied and the install never completes
        Sid    = "Allow the kms-provider operator role"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.operator_role_prefix}-kube-system-kms-provider"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "kms-etcd-${local.cluster_name}"
  }
}

resource "aws_kms_alias" "etcd" {
  count = var.etcd_encryption ? 1 : 0

  name          = "alias/${local.cluster_name}-etcd"
  target_key_id = aws_kms_key.etcd[0].key_id
}

