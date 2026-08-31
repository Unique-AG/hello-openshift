# Naming Module

Centralized naming and tagging module for AWS resources with service-specific length constraints.

## Features

- ✅ Consistent naming across all resources
- ✅ AWS service-specific length constraints
- ✅ Standard tags for governance and cost allocation
- ✅ Drift-free deterministic outputs
- ✅ Swiss data residency tagging

## Usage

```hcl
module "naming" {
  source = "./modules/naming"

  # Required
  org         = "unique"
  org_moniker = "uq"
  client      = "acme"
  layer       = "bootstrap"  # Layer identifier (tracked in tags, not resource names)
  environment = "prod"

  # Deterministic (recommended for CI/CD)
  aws_account_id = "123456789012"
  aws_region     = "eu-central-2"

  # Governance tracking
  semantic_version = "1.0.0"
  deployed_at      = "2024-12-05T12:00:00Z"
}
```

## Examples

### EKS Cluster

```hcl
resource "aws_eks_cluster" "main" {
  name = module.naming.eks_cluster_name  # eks-uq-acme-prod-euc2
  tags = module.naming.tags  # Includes layer:Name = "bootstrap"
}
```

### S3 Bucket

```hcl
resource "aws_s3_bucket" "documents" {
  bucket = "${module.naming.s3_bucket_full}-documents"  # s3-uq-acme-p-euc2-123456789012-documents
  tags   = module.naming.tags  # Includes layer:Name = "bootstrap"
}
```

### DynamoDB Table

```hcl
resource "aws_dynamodb_table" "main" {
  name = "${module.naming.dynamodb_table_prefix}-data"  # dynamodb-uq-acme-prod-euc2-data
  tags = module.naming.tags  # Includes layer:Name = "bootstrap"
}
```

### KMS Key

```hcl
resource "aws_kms_alias" "main" {
  name          = "alias/${module.naming.kms_alias_prefix}-rds"  # alias/kms-uq-acme-prod-rds
  target_key_id = aws_kms_key.main.key_id
}
```

### RDS Instance

```hcl
resource "aws_db_instance" "main" {
  identifier = module.naming.rds_identifier  # rds-uq-acme-prod
  tags       = module.naming.tags
}
```

### IAM Role

```hcl
resource "aws_iam_role" "main" {
  name = "${module.naming.iam_role_prefix}-ec2"  # iam-uq-acme-prod-ec2
  tags = module.naming.tags
}
```

### IAM Policy

```hcl
resource "aws_iam_policy" "main" {
  name = "${module.naming.iam_policy_prefix}-s3-access"  # iam-uq-acme-prod-s3-access
  # ...
}
```

### ALB

```hcl
resource "aws_lb" "main" {
  name = module.naming.lb_name  # alb-uq-acme-p
  tags = module.naming.tags
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `org` | Organization identifier | `string` | `"unique"` | no |
| `org_moniker` | Organization moniker (short abbreviation) | `string` | `"uq"` | no |
| `client` | Client identifier | `string` | - | **yes** |
| `layer` | Layer identifier (e.g., 01-bootstrap, 02-governance) | `string` | - | **yes** |
| `environment` | Environment (prod, stag, dev, sbx) | `string` | - | **yes** |
| `aws_account_id` | AWS Account ID (for deterministic plans) | `string` | `null` | no |
| `aws_region` | AWS Region (for deterministic plans) | `string` | `null` | no |
| `semantic_version` | Semantic version (e.g., 1.0.0) | `string` | `"0.0.0"` | no |
| `deployed_at` | Deployment timestamp (from CI/CD) | `string` | `"1970-01-01T00:00:00Z"` | no |

## Outputs

### Core IDs

| Output | Example | Description |
|--------|---------|-------------|
| `id` | `uq-acme-prod-euc2` | Full resource ID (layer tracked in tags, not names) |
| `id_short` | `uq-acme-p-euc2` | Short ID for length-constrained resources |
| `id_full` | `uq-acme-prod-euc2` | Full ID (same as id) |

### Resource-Specific Names

All resource names include a resource type moniker prefix for clarity and best practices.

| Output | Max Length | Format | Example |
|--------|------------|--------|---------|
| `s3_bucket_full` | 63 | `s3-{id_short}-{account_id}` | `s3-uq-acme-p-euc2-123456789012` |
| `dynamodb_table_prefix` | 255 | `dynamodb-{id}` | `dynamodb-uq-acme-prod-euc2` |
| `kms_alias_prefix` | 256 | `kms-{id}` | `kms-uq-acme-prod-euc2` |
| `iam_role_prefix` | 50 | `iam-{id}` | `iam-uq-acme-prod-euc2` |
| `iam_policy_prefix` | 100 | `iam-{id}` | `iam-uq-acme-prod-euc2` |
| `eks_cluster_name` | 100 | `eks-{id}` | `eks-uq-acme-prod-euc2` |
| `rds_identifier` | 63 | `rds-{id}` | `rds-uq-acme-prod-euc2` |
| `elasticache_cluster_id` | 50 | `elasticache-{id_short}` | `elasticache-uq-acme-p-euc2` |
| `lb_name` | 32 | `alb-{id_short}` | `alb-uq-acme-p-euc2` |
| `tg_name_prefix` | 28 | `tg-{id_short}` | `tg-uq-acme-p-euc2` |
| `lambda_prefix` | 50 | `lambda-{id}` | `lambda_uq_acme_prod_euc2` |
| `sg_name_prefix` | 255 | `sg-{id}` | `sg-uq-acme-prod-euc2` |

### Context

| Output | Description |
|--------|-------------|
| `account_id` | AWS Account ID |
| `region` | AWS Region |
| `environment` | Environment name |
| `environment_short` | Environment short code (p/s/d/x) |

### Tags

| Output | Description |
|--------|-------------|
| `tags` | Standard resource tags (map) |
| `tags_as_list` | Tags as list (for ASG) |

## Drift Prevention

⚠️ **Never use `timestamp()` in Terraform!** It causes drift on every plan.

```hcl
# ❌ BAD - causes drift every plan
deployed_at = timestamp()

# ✅ GOOD - set from CI/CD
deployed_at = var.deployed_at
```

For deterministic plans, always pass explicit AWS context:

```hcl
module "naming" {
  source = "..."

  # These prevent data source variance between environments
  aws_account_id = var.aws_account_id  # From CI/CD secrets
  aws_region     = var.aws_region      # Explicit region
  deployed_at    = var.deployed_at     # From CI/CD timestamp
}
```

## Standard Tags

The module automatically generates these tags:

```hcl
{
  # Organization
  "org:Name"          = "unique"
  "org:Domain"        = "unique.ch"
  "org:DataResidency" = "switzerland"

  # Client
  "client:Id"          = "acme"
  "client:Environment" = "prod"

  # Layer (tracked in tags, not resource names)
  "layer:Name" = "bootstrap"

  # Governance
  "governance:SemanticVersion" = "1.0.0"
  "governance:DeployedAt"      = "2024-12-05T12:00:00Z"

  # Automation
  "automation:ManagedBy" = "terraform"
  "automation:Pipeline"  = "github-actions"

  # Cost
  "cost:CostCenter" = "client-acme"
  "cost:Project"    = "acme"
}
```

## Naming Convention

All resource names follow the pattern with a resource type moniker prefix. Layer information is tracked in tags, not resource names:

```
{resource_moniker}-{org_moniker}-{client}-{environment}-{region_code}-{qualifier}

Full ID format: {org_moniker}-{client}-{environment}-{region_code}
Short ID format: {org_moniker}-{client}-{env_short}-{region_code}

Examples:
  s3-uq-acme-p-euc2-123456789012-terraform-state
  dynamodb-uq-acme-prod-euc2-terraform-state-lock
  kms-uq-acme-prod-euc2-terraform-state
  iam-uq-acme-prod-euc2-github-actions
  eks-uq-acme-prod-euc2-cluster
  rds-uq-acme-prod-euc2-postgres
  alb-uq-acme-p-euc2-main
```

**Components:**
- **Resource Moniker**: Service type prefix (s3, dynamodb, kms, iam, etc.)
- **Org Moniker**: Organization abbreviation (uq)
- **Client**: Client identifier (acme)
- **Environment**: Environment name (prod, stag, dev, sbx)
- **Region Code**: AWS region short code (euc2, use1, etc.)
- **Layer**: Tracked in `layer:Name` tag, not in resource names

**Resource Monikers:**
- `s3` - S3 buckets
- `dynamodb` - DynamoDB tables
- `kms` - KMS keys/aliases
- `iam` - IAM roles and policies
- `eks` - EKS clusters
- `rds` - RDS instances
- `elasticache` - ElastiCache clusters
- `alb` / `nlb` - Load balancers
- `tg` - Target groups
- `lambda` - Lambda functions
- `sg` - Security groups

The conventions this module encodes are summarised above; adapt it to your own
organisation's scheme by replacing this module.

