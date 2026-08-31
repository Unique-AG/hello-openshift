#######################################
# AWS Configuration
#######################################

variable "aws_region" {
  description = "The AWS region where resources will be created"
  type        = string
  default     = "eu-central-2"
}

variable "aws_account_id" {
  description = "AWS account ID; set in environments/common.tfvars"
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
  default     = "openshift"
}

variable "client_name" {
  description = "Client full name"
  type        = string
  default     = "OpenShift"
}

variable "environment" {
  description = "Environment name (prod, stag, dev, sbx)"
  type        = string
}

variable "semantic_version" {
  description = "Semantic version"
  type        = string
  default     = "0.0.0"
}

#######################################
# Budget Configuration
#######################################

variable "budget_amount" {
  description = "Monthly budget amount in USD"
  type        = number
  default     = 1000
}

variable "budget_contact_emails" {
  description = "List of email addresses for budget notifications"
  type        = list(string)
  default     = []
}

#######################################
# KMS Configuration
#######################################

variable "kms_deletion_window" {
  description = "Number of days to wait before deleting KMS keys"
  type        = number
  default     = 30
}

variable "kms_enable_rotation" {
  description = "Enable automatic KMS key rotation"
  type        = bool
  default     = true
}

#######################################
# S3 Configuration
#######################################

variable "enable_s3_lifecycle" {
  description = "Enable S3 lifecycle rules for cost optimization"
  type        = bool
  default     = true
}

variable "s3_transition_to_ia_days" {
  description = "Days before transitioning to Infrequent Access"
  type        = number
  default     = 30
}

variable "s3_transition_to_glacier_days" {
  description = "Days before transitioning to Glacier"
  type        = number
  default     = 90
}

#######################################
# Secrets Configuration
#######################################

variable "secrets_recovery_window_days" {
  description = "Recovery window for deleted Secrets Manager secrets (0 = immediate deletion, for sandboxes)"
  type        = number
  default     = 7
}

variable "secrets_rotation_version" {
  description = "Bump to rotate the generated data-service credentials (write-only secret versions)"
  type        = number
  default     = 1
}
