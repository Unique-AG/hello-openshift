#######################################
# Required Variables
#######################################

variable "aws_region" {
  description = "AWS region for ROSA cluster"
  type        = string
  default     = "eu-central-2"
}

variable "aws_account_id" {
  description = "AWS account ID for ROSA cluster"
  type        = string
}

variable "rhcs_token" {
  description = "Red Hat Cloud Services offline API token (legacy; prefer a service account via rhcs_client_id/rhcs_client_secret)"
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}

variable "rhcs_client_id" {
  description = "Red Hat service-account client id (console.redhat.com -> IAM -> Service Accounts)"
  type        = string
  default     = null
}

variable "rhcs_client_secret" {
  description = "Red Hat service-account client secret"
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null
}

variable "environment" {
  description = "Environment name (sbx, dev, test, prod)"
  type        = string
}

#######################################
# Organization Variables
#######################################

variable "org" {
  description = "Organization name"
  type        = string
  default     = "unique"
}

variable "org_moniker" {
  description = "Organization short name"
  type        = string
  default     = "uq"
}

variable "client" {
  description = "Client/project identifier"
  type        = string
  default     = "openshift"
}

variable "semantic_version" {
  description = "Semantic version for tagging"
  type        = string
  default     = "0.1.0"
}

#######################################
# ROSA Cluster Configuration
#######################################

variable "cluster_name" {
  description = "Name of the ROSA cluster"
  type        = string
  default     = null # Will be generated from org/client/env if not provided
}

variable "openshift_version" {
  description = "OpenShift version for the cluster"
  type        = string
  default     = "4.19"
}

variable "rosa_type" {
  description = "ROSA cluster type: 'hcp' (Hosted Control Plane) or 'classic'"
  type        = string
  default     = "hcp"
  validation {
    condition     = contains(["hcp", "classic"], var.rosa_type)
    error_message = "rosa_type must be either 'hcp' or 'classic'"
  }
}

variable "multi_az" {
  description = "Enable multi-AZ deployment"
  type        = bool
  default     = true
}

variable "availability_zones" {
  description = "Availability zones for the cluster (if not specified, uses first 3 in region)"
  type        = list(string)
  default     = null
}

#######################################
# Network Configuration
#######################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (for NAT gateways)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "enable_nat_gateway" {
  description = "Enable NAT gateways for private-subnet egress. A private ROSA HCP cluster needs egress to Red Hat registries and OCM; disabling this will hang the install."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ (cost saving for non-prod)"
  type        = bool
  default     = true
}

variable "use_existing_vpc" {
  description = "Use an existing VPC instead of creating a new one"
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "ID of existing VPC to use (required if use_existing_vpc is true)"
  type        = string
  default     = null
}

variable "existing_private_subnet_ids" {
  description = "IDs of existing private subnets (required if use_existing_vpc is true)"
  type        = list(string)
  default     = null
}

#######################################
# Machine Pool Configuration
#######################################

variable "worker_instance_type" {
  description = "Instance type for worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "worker_replicas" {
  description = "Number of worker node replicas"
  type        = number
  default     = 3
}

variable "worker_min_replicas" {
  description = "Minimum number of worker replicas for autoscaling"
  type        = number
  default     = 2
}

variable "worker_max_replicas" {
  description = "Maximum number of worker replicas for autoscaling"
  type        = number
  default     = 6
}

variable "enable_autoscaling" {
  description = "Enable cluster autoscaling"
  type        = bool
  default     = true
}

#######################################
# Security Configuration
#######################################

variable "private_cluster" {
  description = "Make the cluster private (no public API endpoint)"
  type        = bool
  default     = true # Private by default for security
}

variable "etcd_encryption" {
  description = "Enable etcd encryption with AWS KMS"
  type        = bool
  default     = true
}

#######################################
# Add-ons Configuration
#######################################

variable "enable_cluster_logging" {
  description = "Enable cluster logging to CloudWatch"
  type        = bool
  default     = true
}

variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

#######################################
# Tags
#######################################

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

#######################################
# Cross-Stack Wiring
#######################################

variable "client_name" {
  description = "Client full name (for display/tagging purposes)"
  type        = string
  default     = "OpenShift"
}

variable "state_bucket" {
  description = "S3 bucket holding Terraform state (for reading the foundation stack's outputs); set in environments/common.tfvars"
  type        = string
}

#######################################
# Bedrock Configuration
#######################################

variable "enable_bedrock_logging" {
  description = "Enable Bedrock model invocation logging"
  type        = bool
  default     = true
}

variable "enable_extra_worker_pool" {
  description = "Create an additional autoscaled worker pool beyond the cluster's default pool (only possible once the cluster is ready)"
  type        = bool
  default     = false
}
