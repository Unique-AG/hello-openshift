# 1-foundation

## Overview

Account-level guardrails and the durable, stateful resources the cluster
consumes: the workload KMS key, the data buckets, the spend budget, and the
Secrets Manager entries holding data-service credentials.

## Design rationale

### Separated from the cluster by lifetime, not by type

Everything here outlives the cluster. `2-cluster` can be destroyed and rebuilt —
and during development it repeatedly was — without touching a bucket, a key or a
secret. That boundary is the reason this stack exists: it keeps a `terraform
destroy` of the cluster from taking application data with it.

### Terraform generates credentials, it does not transport them

Secrets for Redis and MinIO are generated here with `random_password` and written
straight into Secrets Manager. They are never rendered into a manifest, a values
file or a Terraform output. External Secrets Operator reads them in-cluster over
IRSA, so the credential path from generation to consumption never passes through
git or an operator's terminal.

PostgreSQL is deliberately *not* here: CloudNativePG generates those credentials
inside the cluster. A rebuild therefore invalidates them, which is what
`scripts/sync-db-passwords.sh` exists to reconcile.

### One workload key, separate from the state key

`0-bootstrap` owns a key that encrypts Terraform state; this stack owns a key
that encrypts workload data. Splitting them means the CI role that can read state
cannot, on its own, decrypt application data.

### Budget as a guardrail

A monthly budget with notification thresholds is defined here rather than in a
governance account, so a sandbox deployment carries its own cost alarm. A ROSA
cluster left running is expensive; the budget is the cheapest possible check
against that.

## Resources

| Resource | Purpose |
|---|---|
| `aws_kms_key.workload` | Customer-managed key for application and AI data |
| `aws_s3_bucket.application_data` | Application object storage |
| `aws_s3_bucket.ai_data` | AI/inference artefacts |
| `aws_secretsmanager_secret.redis` | Redis credentials, generated here |
| `aws_secretsmanager_secret.minio` | MinIO/object-gateway credentials, generated here |
| `aws_budgets_budget.monthly_budget` | Monthly spend cap with notifications |

## Security principles

- **Encryption at rest** — both buckets use the customer-managed workload key.
- **No public access** — public access block is on for every bucket.
- **Versioning and lifecycle** — object versions are retained and expired on a
  defined schedule rather than accumulating indefinitely.
- **Secrets never in git** — generated into Secrets Manager, consumed over IRSA.
- **Least privilege** — the secret ARNs are exported so `2-cluster` can scope the
  External Secrets IAM policy to exactly these secrets, not to `secretsmanager:*`.

## Usage

```bash
make init apply STACK=1-foundation ENV=sbx
```

Outputs consumed by `2-cluster` through `terraform_remote_state`:
`workload_kms_key_arn`, `redis_secret_arn`, `minio_secret_arn`, `secrets_prefix`.
