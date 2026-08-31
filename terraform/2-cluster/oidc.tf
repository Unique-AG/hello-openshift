#######################################
# OIDC Configuration for ROSA HCP
#######################################
#
# ROSA HCP uses OIDC (OpenID Connect) for workload identity.
# This allows Kubernetes service accounts to assume IAM roles.
#
#######################################

# OIDC Configuration for HCP
resource "rhcs_rosa_oidc_config" "oidc" {
  count = var.rosa_type == "hcp" ? 1 : 0

  managed = true
}

# IAM OIDC provider — the trust anchor STS uses to validate the
# operator roles' web-identity tokens. Without it every
# AssumeRoleWithWebIdentity fails with InvalidIdentityToken and the
# cluster sits in "waiting" forever.
resource "aws_iam_openid_connect_provider" "oidc" {
  count = var.rosa_type == "hcp" ? 1 : 0

  url = "https://${rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url}"

  client_id_list = [
    "openshift",
    "sts.amazonaws.com"
  ]

  thumbprint_list = [rhcs_rosa_oidc_config.oidc[0].thumbprint]
}

# Operator IAM Roles for HCP
module "operator_roles" {
  count = var.rosa_type == "hcp" ? 1 : 0

  source  = "terraform-redhat/rosa-hcp/rhcs//modules/operator-roles"
  version = "~> 1.7"

  operator_role_prefix = local.operator_role_prefix
  oidc_endpoint_url    = rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url
  path                 = "/"

  tags = module.ctx.tags
}

#######################################
# IRSA Support for Workloads
#######################################
#
# These outputs are used to configure IRSA (IAM Roles for Service Accounts)
# for workloads deployed on the cluster.
#

# IAM Role for External Secrets Operator
resource "aws_iam_role" "external_secrets" {
  name = "${local.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.rosa_type == "hcp" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url, "https://", "")}" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/${local.cluster_name}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(var.rosa_type == "hcp" ? rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url : "https://rh-oidc.s3.us-east-1.amazonaws.com/${local.cluster_name}", "https://", "")}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.cluster_name}-external-secrets"
  }

  depends_on = [rhcs_rosa_oidc_config.oidc]
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "${local.cluster_name}-external-secrets"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        # Only the secrets published by the foundation stack (secrets.tf)
        Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:hello-openshift/${var.environment}/*"
      },
      {
        # ListSecrets does not support resource-level permissions
        Effect   = "Allow"
        Action   = "secretsmanager:ListSecrets"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = data.terraform_remote_state.foundation.outputs.workload_kms_key_arn
      }
    ]
  })
}

# IAM Role for Bedrock Access
resource "aws_iam_role" "bedrock" {
  name = "${local.cluster_name}-bedrock"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.rosa_type == "hcp" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url, "https://", "")}" : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/${local.cluster_name}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # bedrock consumers: the data-namespace SA and LiteLLM (Conduct)
            "${replace(var.rosa_type == "hcp" ? rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url : "https://rh-oidc.s3.us-east-1.amazonaws.com/${local.cluster_name}", "https://", "")}:sub" = [
              "system:serviceaccount:hello-openshift-data:bedrock",
              "system:serviceaccount:system:litellm"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.cluster_name}-bedrock"
  }

  depends_on = [rhcs_rosa_oidc_config.oidc]
}

resource "aws_iam_role_policy" "bedrock" {
  name = "${local.cluster_name}-bedrock"
  role = aws_iam_role.bedrock.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = "*"
      }
    ]
  })
}
