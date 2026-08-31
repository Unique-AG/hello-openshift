# 0-bootstrap

## Overview

Provisions the Terraform state backend and the CI/CD authentication path. This
is the only stack that has to solve a chicken-and-egg problem: it creates the
S3 bucket its own state will live in.

## Design rationale

### Self-migrating state

The stack starts with local state, creates the bucket and KMS key, then migrates
its own state into that bucket. `scripts/bootstrap.sh <env>` performs both steps
in order and is only run once per environment. Every other stack initialises
straight against the bucket this one created.

### Separate access-log bucket

S3 server access logging cannot target the bucket being logged, so a second
bucket exists purely to receive the state bucket's access logs. It is versioned,
encrypted and blocked from public access on the same terms.

### GitHub OIDC rather than long-lived keys

CI authenticates through an IAM OIDC provider for `token.actions.githubusercontent.com`,
so GitHub Actions assumes a role with a short-lived token. No AWS access keys
exist for CI to leak. The provider is looked up before it is created, so a second
environment in the same account reuses the existing one instead of failing.

### Blast radius

This stack changes almost never. Destroying it orphans every other stack's
state, which is why it is separated from anything that changes on a normal
working day.

## Resources

| Resource | Purpose |
|---|---|
| `aws_s3_bucket.terraform_state` | State for every stack, versioned and KMS-encrypted |
| `aws_s3_bucket.access_logs` | Receives the state bucket's server access logs |
| `aws_s3_bucket_policy.terraform_state` | Denies non-TLS access; restricts to the account |
| `aws_s3_bucket_lifecycle_configuration.terraform_state` | Expires noncurrent state versions |
| `aws_kms_key.terraform_state` | Customer-managed key encrypting state at rest |
| `aws_iam_openid_connect_provider.github` | OIDC trust for GitHub Actions |
| `aws_iam_role.github_actions` | Role CI assumes; scoped to the state bucket |
| `aws_cloudwatch_log_group.terraform` | Terraform run logs |

## Security principles

- **Encryption at rest** — state is encrypted with a customer-managed KMS key, not
  the AWS-managed default, so key policy and rotation are under this account's control.
- **Encryption in transit** — the bucket policy denies any request where
  `aws:SecureTransport` is false.
- **No public access** — public access block is on for both buckets.
- **Versioned state** — noncurrent versions are retained long enough to recover
  from a bad apply, then expired by lifecycle rule.
- **No static CI credentials** — GitHub Actions authenticates by OIDC.

## Usage

```bash
# First time in a new environment (creates the bucket, then migrates state into it)
./scripts/bootstrap.sh sbx

# Thereafter
make init plan STACK=0-bootstrap ENV=sbx
```
