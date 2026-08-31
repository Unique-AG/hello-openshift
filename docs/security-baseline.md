# Security baseline

The security posture this repository targets, and the scanner findings that are
deliberately accepted rather than fixed.

## Posture

| Control | Implementation |
|---|---|
| Cluster API exposure | ROSA HCP private cluster (`private_cluster = true`); the API endpoint has no public IP. Reached via the SSM bastion or the CloudFront path. |
| Node access | No SSH key pairs. The bastion is reached exclusively through AWS Systems Manager Session Manager, which authenticates via IAM and logs every session. |
| Encryption at rest | etcd encryption enabled on the cluster (`etcd_encryption = true`). All S3 buckets and EBS volumes use customer-managed KMS keys created in `1-foundation`. |
| Encryption in transit | TLS terminates at the OpenShift router. The CloudFront path uses HTTPS end to end; the internal ALB's plaintext listener is VPC-internal only. |
| Secret delivery | No operational secrets in git. Terraform generates credentials into AWS Secrets Manager; External Secrets Operator syncs them into the cluster over IRSA. PostgreSQL credentials are generated in-cluster by CloudNativePG and never leave it. The one tracked credential is Zitadel's first-start bootstrap password, which is single-use (see below). |
| Workload identity | IRSA — pods assume IAM roles through the cluster's OIDC provider. No static AWS credentials in any manifest. |
| Network policy | Cilium provides L7 network policies, which is why the cluster is created with `--no-cni` and Cilium is installed before any workload. |
| Sandboxing | OpenShift sandboxed containers (Kata) with peer pods run untrusted agent workloads on separate VMs. |
| Secret scanning | Gitleaks runs as a pre-commit and pre-push hook (`./scripts/setup-hooks.sh`) and over the full history via `./scripts/scan-secrets.sh`. |

## Accepted scanner findings

These are listed in `.trivyignore`. Each is an intentional architectural
decision, and each is also commented at the point of definition in the
Terraform. Re-justify before adding anything to that list.

### AWS-0104 — unrestricted egress on the bastion security group

`terraform/2-cluster/bastion.tf`

The bastion security group has **no inbound rules at all** and the instance has
no key pair; the only way in is SSM Session Manager. Egress to `0.0.0.0/0` is
required for it to reach the SSM service endpoints, the cluster API and Red Hat
registries. Restricting egress to a prefix list would need continuous
maintenance against AWS and Red Hat address ranges for no meaningful gain
against a host that cannot be reached inbound.

### AWS-0054 — HTTP listener on the CloudFront-facing ALB

`terraform/2-cluster/cloudfront-vpc-origin.tf`

The ALB is **internal** — it has no public IP and is reachable only from inside
the VPC or through the CloudFront VPC Origin. CloudFront is configured to
connect over HTTPS only. The `:80` listener exists so operators can curl the
router from inside the VPC while debugging TLS problems. Traffic from the
public internet never reaches it unencrypted.

### AWS-0164 — public subnets assign public IPs on launch

`terraform/2-cluster/vpc.tf`

The public subnets exist to host the NAT gateway and the internet-facing ALB
used by the CloudFront path. Every cluster workload — control plane, worker
nodes, data services — runs in the private subnets. `map_public_ip_on_launch`
is what makes the NAT gateway and ALB addressable; nothing else is placed in
these subnets.

## Sandbox environment relaxations

`sbx` trades durability and isolation for cost and iteration speed. Every item
below is a deliberate sandbox choice and **must be revisited for a production
environment**.

| Relaxation | Where | Production guidance |
|---|---|---|
| Single AZ (`multi_az = false`) | `environments/sbx/2-cluster.tfvars` | Three AZs. Each additional AZ multiplies AZ-bound cost (NAT, subnets, EIPs), but a single-AZ control plane has no failure domain. |
| One shared NAT gateway (`single_nat_gateway = true`) | same | One NAT per AZ, so a zone failure does not remove egress for the whole cluster. |
| 7-day CloudWatch retention | `0-bootstrap.tfvars`, `2-cluster.tfvars` | Retention that matches your audit obligation, typically 365 days or more. |
| 7-day KMS deletion window | `0-bootstrap.tfvars`, `1-foundation.tfvars` | 30 days, the maximum, so an accidental key deletion is recoverable. |
| `secrets_recovery_window_days = 0` | `1-foundation.tfvars` | A non-zero window. Zero permits immediate deletion and immediate re-create, which is convenient when rebuilding and dangerous otherwise. |
| Harbor proxy-cache projects are **public** | `scripts/setup-harbor-projects.sh` | Make them private and issue a robot account. Anonymous pull is acceptable only because the cluster is private, and it removes the need for a pull secret in every namespace. |
| Zitadel bootstrap admin password in the values file | `gitops/environments/sbx/identity/values/zitadel.yaml` | `PasswordChangeRequired: true` is set explicitly, so the credential is single-use. Note it is **not** a Zitadel default: the key is absent from `defaults.yaml` and therefore defaults to false, so the reset must be requested rather than assumed. For production, inject the password from Secrets Manager rather than tracking it. |
| NooBaa standalone (no ODF storage cluster) | `gitops/components/platform/object-storage/` | A full ODF deployment with replication, if object durability matters. |
| Autoscaling floor of 3 workers | `2-cluster.tfvars` | Size to your workload; the floor exists here to keep the sandbox cheap. |

## Production guardrails

The controls this repository cannot enforce from inside a single account, listed
so they are a deliberate decision rather than an oversight.

### Service Control Policies

Applied at the OU level, so they hold even against an account administrator:

| Guardrail | Why |
|---|---|
| Deny `s3:DeleteBucket` on the state bucket | Losing Terraform state orphans every stack. |
| Deny `kms:ScheduleKeyDeletion` on the state and workload keys | Key deletion is unrecoverable after the window and silently destroys data at rest. |
| Deny disabling CloudTrail, Config or GuardDuty | Keeps the audit trail outside the blast radius of a compromised account. |
| Deny `ec2:CreateInternetGateway` / `AttachInternetGateway` outside the network account | The cluster is private by design; this prevents a direct path being added later. |
| Restrict regions to those you operate in | Limits both cost surprises and the surface an attacker can use. |
| Deny root-user actions | Root should be break-glass only. |

### Beyond SCPs

- **Branch protection** on `main` and `deploy`, requiring the CI checks in
  `.github/workflows/` — the checks only protect what they gate.
- **Rotate the credentials that are not IRSA.** The peer-pods IAM user holds a
  static access key by necessity (the cloud-api-adaptor reads it from a
  Kubernetes secret) and the Harbor upstream registry credential is long-lived.
  Everything else uses IRSA and needs no rotation.
- **Terraform state access** is the highest-value target in the account: it
  contains resource identifiers and, for some resources, generated values. The
  CI role's trust policy is scoped to a single branch ref for this reason.

## Reporting

Please follow the [`Unique Security Policy v1`](https://github.com/Unique-AG/license/blob/main/security-policy/v1.md).
