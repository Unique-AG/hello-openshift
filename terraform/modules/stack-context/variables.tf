variable "org" {
  description = "Organization identifier"
  type        = string
}

variable "org_moniker" {
  description = "Organization moniker (short abbreviation)"
  type        = string
}

variable "client" {
  description = "Client identifier"
  type        = string
}

variable "client_name" {
  description = "Client full name (for display/tagging purposes)"
  type        = string
}

variable "environment" {
  description = "Environment name (prod, stag, dev, sbx)"
  type        = string
}

variable "stack" {
  description = "Stack identifier (bootstrap, foundation, cluster)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID (for deterministic naming)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "semantic_version" {
  description = "Semantic version (e.g., 1.0.0). Set by CI/CD"
  type        = string
  default     = "0.0.0"
}

variable "extra_tags" {
  description = "Additional tags merged on top of the standard set"
  type        = map(string)
  default     = {}
}
