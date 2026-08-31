# 2-cluster

## Overview

The VPC, the ROSA HCP cluster, the IAM/IRSA wiring the in-cluster operators
need, the Bedrock inference roles, and the optional CloudFront ingress path.
This is the stack that changes most often and the one that gets rebuilt.

## Design rationale

### The cluster is created by the `rosa` CLI, then imported

This is the most important thing to know about this stack, and the one place it
deviates from being pure Terraform.

Cilium is a hard requirement — the Conduct charts use L7 network policies, which
the default CNI cannot express. Cilium cannot be installed over an existing CNI,
so the cluster must be created with `--no-cni`. The `rhcs` Terraform provider has
no way to express that flag. So:

```bash
rosa create cluster --hosted-cp --no-cni ...     # create out of band
terraform import 'rhcs_cluster_rosa_hcp.cluster[0]' <cluster-id>
```

Cilium is then installed by `gitops/bootstrap/cilium` **before any workload
lands**. A cluster brought up without this sequence has no working datapath.

One consequence worth knowing: the `network` cluster-operator stays permanently
Degraded, because multus crash-loops when nothing populates
`/run/multus/cni/net.d`. Cilium carries the datapath. `scripts/smoke-test.sh`
treats that single degradation as expected rather than as a failure.

### Pin the OpenShift patch version, not the minor

`openshift_version` is resolved with

```hcl
[for v in data.rhcs_versions.all.items : v.name if startswith(v.name, var.openshift_version)][0]
```

and that list is **not ordered**. A bare `"4.19"` therefore resolves to whichever
patch the OCM API happens to return first. That silently drifts: if the live
cluster is newer, the apply fails with *"already above the requested version"*;
if it is older, Terraform schedules an upgrade nobody asked for. Always pin the
full patch.

### Peer-pods uses an IAM user, deliberately

Every other AWS identity here is a role assumed over IRSA. The
sandboxed-containers cloud-api-adaptor is the exception: it launches pod VMs with
*static* credentials read from a Kubernetes secret, so it needs an IAM user. The
access key is created out of band with the AWS CLI and written straight to
Secrets Manager, so no key material ever enters Terraform state.

### CloudFront reaches the router through an ALB, not the NLB

The router NLB that Kubernetes creates has no security group, and a security
group is required for a CloudFront VPC Origin — attachable only at NLB creation
time. So an internal ALB fronts the router and the VPC Origin points at the ALB.
The origin is RAM-shared to the connectivity account, where the public DNS zone
and the CloudFront distribution live.

### Harbor resolves through a private zone, on our own domain

`aws_route53_zone.harbor_private` serves `harbor.<your-domain>` inside the VPC,
pointing at the registry's internal ELB. This is deliberate: the registry
endpoint every image reference uses stays **off** the cluster apps domain, so it
survives a cluster rebuild untouched and the image references never need
rewriting. The Harbor *UI* Route does live on the apps domain, and does change on
rebuild.

### Cross-stack reads, not copied values

`terraform_remote_state.foundation` supplies the workload KMS key and the secret
ARNs. The External Secrets IAM policy is scoped to exactly those ARNs rather than
to `secretsmanager:*`.

## Resources

| Group | Resources |
|---|---|
| Network | `aws_vpc.main`, public/private/ALB subnets, `aws_nat_gateway.main`, `aws_internet_gateway.main`, route tables, `aws_vpc_endpoint.s3` |
| Cluster | `rhcs_cluster_rosa_hcp.cluster`, `rhcs_hcp_machine_pool.worker`, `rhcs_rosa_oidc_config.oidc`, `module.account_roles`, `module.operator_roles` |
| Encryption | `aws_kms_key.etcd` |
| Workload identity | `aws_iam_openid_connect_provider.oidc`, `aws_iam_role.external_secrets`, `aws_iam_role.bedrock` |
| Inference | `aws_bedrock_model_invocation_logging_configuration.main`, `aws_iam_role.bedrock_logging`, `aws_cloudwatch_log_group.bedrock_logs` |
| Sandboxing | `aws_iam_user.peer_pods` and its policies |
| Ingress (optional) | `aws_lb.cloudfront`, listeners, `aws_acm_certificate.internal_alb`, `aws_cloudfront_vpc_origin.internal_alb`, `aws_ram_*` |
| Registry DNS | `aws_route53_zone.harbor_private` |
| Access | `aws_instance.bastion` (SSM only), `aws_iam_role.bastion` |

## Security principles

- **Private cluster** — `private_cluster = true`; the API endpoint has no public IP.
- **etcd encryption** — enabled against a customer-managed KMS key.
- **No SSH** — the bastion has no key pair and no inbound rules; access is
  exclusively through SSM Session Manager, which is IAM-authenticated and logged.
- **IRSA everywhere it is possible** — pods assume roles through the cluster's OIDC
  provider. The one static credential (peer-pods) is documented above and kept
  out of Terraform state.
- **Least-privilege policies** — the External Secrets policy names the exact secret
  ARNs exported by `1-foundation`.
- **Workloads in private subnets** — the public subnets carry only the NAT gateway
  and the internet-facing ALB.

Three trivy findings here are accepted rather than fixed; see
[`docs/security-baseline.md`](../../docs/security-baseline.md).

## Usage

```bash
export TF_VAR_rhcs_client_id=... TF_VAR_rhcs_client_secret=...
make init apply STACK=2-cluster ENV=sbx     # 40-60 min
make output STACK=2-cluster
```
