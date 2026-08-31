#######################################
# AWS Configuration
#######################################

variable "aws_region" {
  description = "The AWS region where resources will be created"
  type        = string
  default     = "eu-central-2"
}

variable "aws_account_id" {
  description = "AWS account ID (for deterministic naming); set in environments/common.tfvars"
  type        = string
}

#######################################
# Organization Variables
#######################################

variable "org" {
  description = "Organization identifier"
  type        = string
  default     = "unique"
}

variable "org_moniker" {
  description = "Organization moniker (short abbreviation)"
  type        = string
  default     = "uq"
}

variable "client" {
  description = "Client identifier"
  type        = string
  default     = "hello-openshift"
}

variable "client_name" {
  description = "Client full name (for display/tagging purposes)"
  type        = string
  default     = "Hello OpenShift"
}

variable "environment" {
  description = "Environment name (prod, stag, dev, sbx)"
  type        = string
}

variable "semantic_version" {
  description = "Semantic version (e.g., 1.0.0). Set by CI/CD"
  type        = string
  default     = "0.0.0"
}

#######################################
# S3 Configuration
#######################################

variable "enable_versioning" {
  description = "Enable versioning on the S3 bucket"
  type        = bool
  default     = true
}

variable "enable_server_side_encryption" {
  description = "Enable server-side encryption on the S3 bucket"
  type        = bool
  default     = true
}

variable "enable_public_access_block" {
  description = "Enable S3 public access block"
  type        = bool
  default     = true
}

#######################################
# GitHub Actions OIDC
#######################################

variable "use_oidc" {
  description = "Whether to use OIDC for authentication (for CI/CD)"
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo' for OIDC trust relationship"
  type        = string
  default     = ""
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub Actions IAM OIDC provider in this account.

    An account can hold only one provider per URL, and many organisations create
    it once centrally. Leave false to reuse the existing one (it is then looked
    up), set true for an account that has none. This is an explicit choice
    because the previous "create it if the lookup finds nothing" conditional
    could never be true -- the data source it tested was itself gated on the
    same predicate -- so the provider was never creatable, and the lookup
    hard-failed the plan on an account without one.
  EOT
  type        = bool
  default     = false
}

variable "github_actions_subjects" {
  description = <<-EOT
    Token subjects allowed to assume the GitHub Actions role.

    Defaults to the deploy branch only. The role can write Terraform state and
    use the state KMS key, so `repo:<owner>/<repo>:*` -- which trusts every
    branch, tag, pull request and environment in the repository, including a
    branch pushed by anyone who can open one -- is too broad to be the default.
  EOT
  type        = list(string)
  default     = []
}

variable "github_oidc_thumbprints" {
  description = <<-EOT
    Certificate thumbprints for the GitHub OIDC provider.

    IAM no longer validates these for token.actions.githubusercontent.com, but
    the argument is still required. Both currently published intermediates are
    listed so a rotation does not need a code change.
  EOT
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

#######################################
# Retention Configuration
#######################################

variable "kms_deletion_window" {
  description = "Number of days to wait before deleting KMS keys"
  type        = number
  default     = 30
}

variable "cloudwatch_log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 30
}
