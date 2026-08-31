#######################################
# GitHub Actions OIDC Role
#######################################

# GitHub OIDC Provider
#
# Exactly one of these two is active, selected by create_github_oidc_provider.
# The previous shape gated the resource on `length(data...) == 0` while the data
# source was gated on the same predicate as the resource, so the length was
# always 1 when it mattered and the resource was unreachable -- while the data
# source hard-failed the plan on an account that had no provider yet.
data "aws_iam_openid_connect_provider" "github" {
  count = local.gha_enabled && !var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.gha_enabled && var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = local.tags
}

# IAM Role for GitHub Actions
resource "aws_iam_role" "github_actions" {
  count = local.gha_enabled ? 1 : 0

  name = local.github_actions_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # one() over the concatenated lists: exactly one of the two is
          # non-empty. `try(data[0].arn, resource[0].arn)` looked like a
          # fallback but could only ever index whichever list was empty.
          Federated = one(concat(
            data.aws_iam_openid_connect_provider.github[*].arn,
            aws_iam_openid_connect_provider.github[*].arn,
          ))
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = local.gha_subjects
          }
        }
      }
    ]
  })

  tags = merge(
    local.tags,
    {
      Name        = local.github_actions_role_name
      Description = "IAM role for GitHub Actions OIDC authentication"
    }
  )
}

# Attach policies to GitHub Actions role
resource "aws_iam_role_policy_attachment" "github_actions_s3" {
  count      = var.use_oidc && var.github_repository != "" ? 1 : 0
  role       = aws_iam_role.github_actions[0].name
  policy_arn = aws_iam_policy.terraform_state_access[0].arn
}
