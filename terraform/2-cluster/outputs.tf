#######################################
# ROSA Cluster Outputs
#######################################
#
# Outputs for connecting to and configuring
# the ROSA cluster after deployment.
#
#######################################

#######################################
# Cluster Information
#######################################

output "cluster_id" {
  description = "ROSA cluster ID"
  value       = var.rosa_type == "hcp" ? rhcs_cluster_rosa_hcp.cluster[0].id : null
}

output "cluster_name" {
  description = "ROSA cluster name"
  value       = local.cluster_name
}

output "cluster_api_url" {
  description = "ROSA cluster API URL"
  value       = var.rosa_type == "hcp" ? rhcs_cluster_rosa_hcp.cluster[0].api_url : null
}

output "cluster_console_url" {
  description = "ROSA cluster console URL"
  value       = var.rosa_type == "hcp" ? rhcs_cluster_rosa_hcp.cluster[0].console_url : null
}

output "cluster_domain" {
  description = "ROSA cluster domain"
  value       = var.rosa_type == "hcp" ? rhcs_cluster_rosa_hcp.cluster[0].domain : null
}

output "openshift_version" {
  description = "OpenShift version deployed"
  value       = local.rosa_version
}

#######################################
# Network Information
#######################################

output "vpc_id" {
  description = "VPC ID where the cluster is deployed"
  value       = var.use_existing_vpc ? var.existing_vpc_id : aws_vpc.main[0].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = local.private_subnet_ids
}

output "availability_zones" {
  description = "Availability zones used by the cluster"
  value       = local.azs
}

#######################################
# OIDC Configuration
#######################################

output "oidc_endpoint_url" {
  description = "OIDC endpoint URL for workload identity"
  value       = var.rosa_type == "hcp" ? rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url : null
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IAM role trust policies"
  value       = var.rosa_type == "hcp" ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(rhcs_rosa_oidc_config.oidc[0].oidc_endpoint_url, "https://", "")}" : null
}

#######################################
# IAM Roles
#######################################

output "installer_role_arn" {
  description = "ROSA installer role ARN"
  value       = local.installer_role_arn
}

output "support_role_arn" {
  description = "ROSA support role ARN"
  value       = local.support_role_arn
}

output "worker_role_arn" {
  description = "ROSA worker role ARN"
  value       = local.worker_role_arn
}

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets.arn
}

output "bedrock_role_arn" {
  description = "IAM role ARN for Bedrock access"
  value       = aws_iam_role.bedrock.arn
}

#######################################
# Encryption
#######################################

output "etcd_kms_key_arn" {
  description = "KMS key ARN for etcd encryption"
  value       = var.etcd_encryption ? aws_kms_key.etcd[0].arn : null
}

output "etcd_kms_key_id" {
  description = "KMS key ID for etcd encryption"
  value       = var.etcd_encryption ? aws_kms_key.etcd[0].key_id : null
}

#######################################
# CloudWatch Logging
#######################################

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for cluster logs"
  value       = var.enable_cluster_logging ? aws_cloudwatch_log_group.rosa[0].name : null
}

#######################################
# Connection Information
#######################################

output "oc_login_command" {
  description = "Command to login to the cluster (requires cluster-admin credentials)"
  value       = var.rosa_type == "hcp" ? "oc login ${rhcs_cluster_rosa_hcp.cluster[0].api_url} --username cluster-admin" : null
}

output "rosa_describe_command" {
  description = "Command to describe the ROSA cluster"
  value       = "rosa describe cluster --cluster=${local.cluster_name}"
}

#######################################
# Bedrock (Inference)
#######################################

output "bedrock_log_group_name" {
  description = "Name of the Bedrock model-invocation CloudWatch log group"
  value       = var.enable_bedrock_logging ? aws_cloudwatch_log_group.bedrock_logs[0].name : null
}

output "bedrock_logging_role_arn" {
  description = "ARN of the Bedrock logging IAM role"
  value       = var.enable_bedrock_logging ? aws_iam_role.bedrock_logging[0].arn : null
}
