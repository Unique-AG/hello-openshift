output "id" {
  description = "Canonical resource id: {org_moniker}-{client}-{env}-{region_short}"
  value       = module.naming.id
}

output "s3_bucket_prefix" {
  description = "Prefix for S3 bucket names"
  value       = module.naming.s3_bucket_prefix
}

output "iam_role_prefix" {
  description = "Prefix for IAM role names"
  value       = module.naming.iam_role_prefix
}

output "iam_policy_prefix" {
  description = "Prefix for IAM policy names"
  value       = module.naming.iam_policy_prefix
}

output "tags" {
  description = "Standard tags for all resources in the stack"
  value = merge(
    module.naming.tags,
    { "client:Name" = var.client_name },
    var.extra_tags
  )
}
