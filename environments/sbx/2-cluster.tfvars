# Sandbox environment — 2-cluster stack (ROSA HCP)

environment = "sbx"

# Cross-stack wiring: bucket holding the foundation stack's state
state_bucket = "s3-<org>-<client>-x-<region>-tfstate"

# ROSA Configuration
rosa_type         = "hcp"
# Pin the exact patch, not just the minor. locals resolves this with
# [for v in data.rhcs_versions.all.items : v.name if startswith(v.name, var.openshift_version)][0]
# and that list is NOT ordered, so a bare "4.19" resolves to whatever the OCM API
# happens to return first (4.19.10 in Aug 2026). That silently drifts: if the live
# cluster is newer the apply fails with "Can't upgrade cluster ... already above the
# requested version", and if it is older Terraform schedules an unrequested upgrade.
openshift_version = "4.19.42"
multi_az          = false # Single AZ for sandbox to reduce costs

# Network Configuration
vpc_cidr             = "10.0.0.0/16"
private_subnet_cidrs = ["10.0.1.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24"]

# Egress: private HCP clusters need NAT to reach Red Hat registries/OCM.
# One shared gateway keeps sandbox cost down (~$37/month in eu-central-2).
enable_nat_gateway = true
single_nat_gateway = true

# Machine Pool Configuration
worker_instance_type = "m6i.2xlarge" # hello-aws steady group sizing (8 vCPU / 32 GiB)
worker_replicas      = 3
enable_autoscaling   = true
worker_min_replicas  = 3
worker_max_replicas  = 6

# Security Configuration
private_cluster = true
etcd_encryption = true

# Inference (Bedrock)
enable_bedrock_logging = true

# Platform capacity: extra autoscaled pool (creatable only on a ready cluster);
# the default "workers" pool (m5.xlarge x2) remains the bootstrap substrate
enable_extra_worker_pool = false

# Logging
enable_cluster_logging        = true
cloudwatch_log_retention_days = 7 # Shorter retention for sandbox

# CloudFront VPC Origin (openshift.example.com lives in the connectivity
# account; the origin is RAM-shared to it). CloudFront reaches the router
# through an internal ALB because the k8s-created router NLB has no security
# group (required for VPC origins, attachable only at NLB creation).
enable_cloudfront_vpc_origin    = true
connectivity_account_id         = "210987654321"
internal_alb_certificate_domain = "*.openshift.example.com"
# Flip to true after the connectivity stack created the ACM validation CNAME
# and the certificate is ISSUED (HTTPS listeners reject pending certificates).
internal_alb_https_enabled = true
