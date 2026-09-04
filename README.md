# hello-openshift

An OpenShift-native reference deployment of the Unique AI platform, built to
simulate on-premises patterns: Kubernetes operators in place of AWS PaaS
services, and GitOps in place of imperative deployment.

It is the sibling of [hello-aws](https://github.com/Unique-AG/hello-aws), which
deploys the same platform onto EKS using managed AWS services. This repository
answers the opposite question — what the platform looks like when the managed
services are not available.

## Overview

Every managed service hello-aws relies on is replaced by something that could
equally run in a customer's own datacentre:

| hello-aws (AWS PaaS) | hello-openshift replacement | Operator / tool |
|---|---|---|
| Aurora PostgreSQL | CloudNativePG | `cloudnative-pg` |
| ElastiCache Redis | Redis Operator (OT-CONTAINER-KIT) | `redis-operator` |
| S3 (object storage) | ODF Multicloud Object Gateway (NooBaa, standalone) | `odf-operator` |
| Secrets Manager (delivery) | External Secrets Operator | `external-secrets-operator` |
| EKS | ROSA HCP (Red Hat OpenShift on AWS) | Terraform `rhcs` provider |
| VPC CNI | Cilium (required for L7 network policies) | `cilium` |
| ECR | Harbor (proxy-cache projects) | `harbor` |

AWS is still the substrate — the cluster runs on ROSA and inference runs on
Bedrock — but nothing inside the cluster depends on an AWS-only API.

## Architecture

### Division of labour

Terraform provisions AWS and the cluster. ArgoCD owns everything inside the
cluster. The boundary is strict: there are no `kubectl apply` steps in the
deployment path after bootstrap, and no Terraform resource reaches into the
cluster.

### Stacks

Terraform is split into stacks by blast radius and lifetime. Resources that
change together live together, and stateful resources are separated from the
cluster so the cluster can be destroyed and rebuilt without them.

| Stack | Contents | Changes |
|---|---|---|
| [`0-bootstrap`](terraform/0-bootstrap/) | State backend (S3, KMS), GitHub OIDC role | Almost never |
| [`1-foundation`](terraform/1-foundation/) | Budget, workload KMS key, data buckets, Secrets Manager entries | Rarely |
| [`2-cluster`](terraform/2-cluster/) | VPC, ROSA HCP, IAM/IRSA, Bedrock, CloudFront ingress | Often |

Each stack keeps its own state file in the bucket `0-bootstrap` creates. Stacks
read each other through `terraform_remote_state`, never through copied values.

### GitOps layers

Inside the cluster, one ApplicationSet generates an Application per spec in
`gitops/environments/<env>/apps/`, applied in sync-wave order. The ordering is
load-bearing: operators must be Established before their custom resources
exist, and Cilium must own the datapath before any workload starts.

| Wave | Layer | Contents |
|---|---|---|
| 1 | Cilium, operators | CNI; operator subscriptions |
| 2 | Platform | Namespaces, External Secrets, SCCs, Kata |
| 3 | Data services, Harbor | CloudNativePG, Redis, NooBaa; registry |
| 4 | Identity, Conduct | Zitadel; Conduct prerequisites |
| 5 | Supporting services | LiteLLM, RabbitMQ, Qdrant, agent-sandbox, Zitadel config |
| 6 | Application slice | chat / admin / knowledge-upload frontends and the seven backends |

### Network access model

The cluster is private by default: the API endpoint has no public IP, and access
is through SSM Session Manager. Public access to the application is optional and
goes through CloudFront:

```
CloudFront → VPC Origin → internal ALB → OpenShift router → Service
```

The ALB exists because a CloudFront VPC Origin requires a security group, and the
router NLB that Kubernetes creates has none — a security group can only be
attached to an NLB at creation time. The origin is RAM-shared to the
connectivity account, where the public DNS zone and the distribution live. Set
`enable_cloudfront_vpc_origin = false` for a fully private deployment.

## File organization

```
hello-openshift/
├── environments/                # Single source of environment config
│   ├── common.tfvars.template   #   copy to common.tfvars (gitignored)
│   └── sbx/                     #   per-stack tfvars + static backend files
├── terraform/
│   ├── modules/
│   │   ├── naming/              #   name and tag construction
│   │   └── stack-context/       #   shared naming + tagging per stack
│   ├── 0-bootstrap/
│   ├── 1-foundation/
│   └── 2-cluster/
├── gitops/
│   ├── bootstrap/               # Hand-applied once: GitOps operator, Cilium, root app
│   ├── components/              # Environment-agnostic bases
│   └── environments/sbx/        # App-of-apps root + environment overlays
├── scripts/                     # Bootstrap, propagation, verification, secret scanning
├── docs/                        # Security baseline
└── Makefile                     # Terraform stack runner
```

### Principles

- **One `environments/` directory, not one per stack.** The Makefile passes the
  common file and the per-stack file explicitly (`-var-file`), so there is a
  single copy of every shared value in the repository.
- **`context.tf` per stack, not duplicated `naming.tf` + `locals.tf` + `data.tf`.**
  Each stack instantiates `modules/stack-context` once; the shared naming and
  tagging logic exists in exactly one place.
- **Descriptive file names.** `s3.tf`, `iam-roles.tf`, `vpc.tf` — no numeric
  prefixes. Terraform derives execution order from dependencies, not file order.
- **Environment-agnostic bases, environment-specific overlays.** Anything under
  `gitops/components/` must build for any environment; anything cluster-specific
  lives in `gitops/environments/<env>/`. Where a base object needs one
  environment-specific field — Harbor's ELB certificate ARN, the External
  Secrets IRSA role — the field is patched from the overlay rather than baked
  into the base.
- **Values that change on rebuild live in exactly one file.** The cluster domain
  and the Zitadel object IDs are each declared once and propagated by script —
  see [Operations](#operations).

### Naming module

`terraform/modules/naming/` constructs length-constrained resource names and a
standard tag set. `modules/stack-context/` wraps it with per-stack context so a
stack needs one module block rather than a naming block plus a locals block.
Replace both with your own conventions if you have them.

## Prerequisites

- An AWS account (the sandbox OU, for this configuration) — account id goes in
  `environments/common.tfvars`
- A Red Hat Cloud Services service account — console.redhat.com → IAM → Service
  Accounts, granted OCM access
- Terraform >= 1.11, AWS CLI, `oc`, `rosa`, and `kustomize`
- `gitleaks` for the pre-commit hooks

## Common configuration

`environments/common.tfvars` holds the values shared by every stack, and is
gitignored because it carries the account id. Create it from the template:

```bash
cp environments/common.tfvars.template environments/common.tfvars
```

Per-stack, per-environment values live in `environments/<env>/<stack>.tfvars`
and *are* tracked. Backend configuration is static, in
`environments/<env>/backend/<stack>.s3.tfbackend`.

## Deployment workflow

### 0. One-time setup

```bash
./scripts/setup-hooks.sh
cp environments/common.tfvars.template environments/common.tfvars   # fill in account id
```

### 1. State backend

Creates the bucket and migrates its own state into it. Once per environment.

```bash
./scripts/bootstrap.sh sbx
```

### 2. Foundation

```bash
make init apply STACK=1-foundation ENV=sbx
```

### 3. Cluster

```bash
export TF_VAR_rhcs_client_id=... TF_VAR_rhcs_client_secret=...
make init apply STACK=2-cluster ENV=sbx        # 40-60 min
```

> **The cluster itself is created out of band and imported.** Cilium is a hard
> requirement for the L7 network policies the Conduct charts use, Cilium cannot
> be installed over an existing CNI, and the `rhcs` provider cannot express
> `--no-cni`. So the cluster is created with `rosa create cluster --hosted-cp
> --no-cni ...` and then `terraform import`ed. See
> [`terraform/2-cluster/README.md`](terraform/2-cluster/README.md).

### 4. GitOps

```bash
oc apply -k gitops/bootstrap
oc wait --for=condition=Established crd/applications.argoproj.io --timeout=300s
oc -n openshift-gitops rollout status deploy/openshift-gitops-server
# create the repo-hello-openshift deploy-key secret — see gitops/bootstrap/README.md
oc apply -k gitops/bootstrap/envs/sbx
```

Cilium is installed by `gitops/bootstrap/cilium` **before any workload**.

From here on, changes under `gitops/` deploy by merging to the `deploy` branch,
which is what every ArgoCD Application tracks (`targetRevision: deploy`).
ArgoCD syncs the waves in order automatically. A fresh clone has no `deploy`
branch — create it before this step, or every Application fails to resolve its
source:

```bash
git switch -c deploy main && git push -u origin deploy
```

The branching model, how a release is cut and adopted, and how to track this
repository as an upstream from your own private copy are in
[`docs/release-concept.md`](docs/release-concept.md).

### 5. Verify

```bash
scripts/smoke-test.sh
```

One shallow check per layer, PASS/FAIL each. It proves layers are serving, not
that they are correct.

## State management

| Stack | State key |
|---|---|
| `0-bootstrap` | `bootstrap/terraform.tfstate` |
| `1-foundation` | `sbx/foundation.tfstate` |
| `2-cluster` | `sbx/cluster.tfstate` |

`0-bootstrap` is not environment-prefixed because one state backend serves every
environment in the account; the other stacks are.

All three live in the bucket created by `0-bootstrap`, encrypted with that
stack's KMS key, versioned, with noncurrent versions expired by lifecycle rule.
Cross-stack reads go through `terraform_remote_state`; no value is copied by
hand between stacks.

## Operations

Some values change on every cluster rebuild and are embedded in many files.
Each has a single source of truth and a script that propagates it **by key**, so
propagation is idempotent from any starting state.

| Script | Purpose |
|---|---|
| `bootstrap.sh` | Create the state backend and migrate state into it |
| `configure-instance.sh` | Stamp an environment's `instance-config.yaml` into the gitops tree (`--check` to report drift) |
| `validate-instance.sh` | Refuse a tree that still holds placeholders or unset values |
| `set-harbor-dns.sh` | Point the Harbor record at the internal ELB |
| `setup-harbor-projects.sh` | Create Harbor registry endpoints and proxy-cache projects |
| `sync-db-passwords.sh` | Re-point stored credentials at the current CloudNativePG password |
| `apply-cluster-admin-steps.sh` | The cluster-level settings ArgoCD cannot manage |
| `check-asm-secrets.sh` | Inventory every Secrets Manager secret this deployment consumes |
| `smoke-test.sh` | One pass over every layer |
| `scan-secrets.sh` | Gitleaks over the full history |
| `setup-hooks.sh` | Install the pre-commit and pre-push hooks |

One file carries a live cluster's identity. Create it from the template, fill
it in, and stamp it into the tree:

```bash
cp gitops/instance-config.yaml.template gitops/environments/sbx/instance-config.yaml
# edit it, then
./scripts/configure-instance.sh sbx
./scripts/validate-instance.sh sbx
```

A stale value is severe, and the file's own annotations say exactly how each one
fails. A stale `cluster.domain` takes every node NotReady, because it is
Cilium's `k8sServiceHost` and `kubeProxyReplacement` leaves no service-IP
fallback. A stale `zitadel.projectId` makes every authenticated request look
role-less, and the resulting "Forbidden resource" arrives inside an HTTP 200.

`configure-instance.sh` is idempotent from any starting state: it records what
it last applied in `.instance-applied.yaml`, so it always knows the exact string
it is replacing.

### Values with no propagation script

The cluster domain and the Zitadel IDs are script-propagated. These are not —
they are placeholders in tracked manifests and must be filled in by hand before
the first ArgoCD sync. There is no single source of truth for them yet, which is
the honest limit of the mechanism above:

| Placeholder | Where | What it needs |
|---|---|---|
| `123456789012` | `gitops/environments/sbx/platform/kustomization.yaml`, `conduct/cm-litellm-aws-config.yaml`, `conduct/values/litellm.yaml` | Your AWS account id, in the IRSA role ARNs for External Secrets and Bedrock (`make output STACK=2-cluster` reports both role ARNs) |
| `arn:aws:acm:…:certificate/00000000-…` | `gitops/environments/sbx/platform/kustomization.yaml` (patch) | The ACM certificate ARN for the Harbor registry ELB |
| `openshift.example.com` | Route hosts and service URLs across `gitops/environments/sbx/` | Your own DNS zone |
| `uniquecr.azurecr.io` / `uniqueapp.azurecr.io` | ArgoCD Application `repoURL`s and Harbor proxy-cache config | Left as-is: these are the registries the Unique charts are published from, not deployment-specific values |

`grep -rn '123456789012\|example\.com\|00000000-0000' gitops/` lists the ones in
this table. The script-propagated values use `<cluster-id>` and `<project-id>`
placeholders instead, so a run of either script tells you if one was missed.

Some cluster-level settings are not GitOps-managed and must be applied once per
cluster by a cluster-admin; `scripts/apply-cluster-admin-steps.sh` makes them
idempotent.

## Environments

`sbx` is the only concrete environment. To add one:

1. `environments/<env>/` — tfvars per stack, plus `backend/<stack>.s3.tfbackend`
2. `gitops/environments/<env>/` — `instance-config.yaml` (from
   `gitops/instance-config.yaml.template`), `apps/`, `value-overlays/`,
   `manifests/` and `argo/`
3. `scripts/configure-instance.sh <env>` to stamp the instance values, then
   `scripts/validate-instance.sh <env>`
4. `oc apply -k gitops/bootstrap/envs/<env>` on that cluster — this creates the
   AppProject, the repo credential and the ApplicationSet that generates one
   Application per spec in `apps/`

See [docs/release-concept.md](docs/release-concept.md) for the branch model and
where each kind of configuration belongs.

Note: `configure-instance.sh` currently rewrites all of `gitops/`, including the
shared `bootstrap/` and `components/` trees, so a second environment first needs
the cluster-specific files moved out of those into its own directory.

## Documentation

| Document | Contents |
|---|---|
| [`docs/release-concept.md`](docs/release-concept.md) | Branching model, the two delivery tracks, how a release is cut and adopted, rollback, and consuming releases in your own private copy |
| [`docs/security-baseline.md`](docs/security-baseline.md) | Security posture, accepted scanner findings with rationale, sandbox relaxations, and production guardrails |
| [`terraform/0-bootstrap`](terraform/0-bootstrap/README.md) · [`1-foundation`](terraform/1-foundation/README.md) · [`2-cluster`](terraform/2-cluster/README.md) | Per-stack design rationale, resources and security principles |
| [`gitops/bootstrap`](gitops/bootstrap/README.md) | The one-time hand-applied bootstrap, including the repo deploy-key secret |
| [`operators`](gitops/components/operators/README.md) · [`platform`](gitops/components/platform/README.md) · [`data-services`](gitops/components/data-services/README.md) · [`identity`](gitops/components/identity/README.md) · [`conduct`](gitops/components/conduct/README.md) · [`chat`](gitops/components/chat/README.md) | One document per GitOps layer: what it contains, why it is in its wave, and the failure modes specific to it |
| [`gitops/environments/sbx/chat`](gitops/environments/sbx/chat/README.md) | Per-service breakdown of the application slice and its chart versions |

## Security

The posture this repository targets, and the scanner findings deliberately
accepted rather than fixed, are documented in
[`docs/security-baseline.md`](docs/security-baseline.md), along with the
sandbox relaxations that must be revisited for production and the guardrails
this repository cannot enforce from inside a single account. In summary: private
cluster, no SSH, IRSA for workload identity, customer-managed KMS keys
throughout, and no operational secrets in git.

### Validation

```bash
make fmt                      # terraform fmt -recursive
make validate                 # init -backend=false + validate, every stack
make lint                     # tflint + trivy
```

CI runs the same checks on every pull request, plus `kustomize build` over every
kustomization in `gitops/` — which is what catches a dangling resource reference
before ArgoCD would surface it at sync time.

### Secret scanning

Gitleaks runs as a pre-commit and pre-push hook, and in CI:

```bash
./scripts/setup-hooks.sh        # install the hooks
./scripts/scan-secrets.sh       # scan the entire history
./scripts/scan-secrets.sh --staged
```

No credential is committed to this repository. Terraform generates data-service
credentials directly into AWS Secrets Manager; External Secrets Operator syncs
them into the cluster over IRSA. PostgreSQL credentials are generated in-cluster
by CloudNativePG and never leave it.

## Contributing

Pull requests should keep CI green: `make fmt validate lint`, and every
kustomization must build. Environment-agnostic changes belong in
`gitops/components/`; anything cluster-specific belongs in
`gitops/environments/<env>/`.

## License

See [LICENSE](LICENSE) — the [Unique License v1](https://github.com/Unique-AG/license/releases/tag/unique-license.v1).

## References

- [hello-aws](https://github.com/Unique-AG/hello-aws) — the EKS/managed-services sibling
- [ROSA HCP documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/)
- [Terraform `rhcs` provider](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs)
- [ArgoCD ApplicationSet](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) · [cluster bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [CloudNativePG](https://cloudnative-pg.io/) · [External Secrets Operator](https://external-secrets.io/) · [Cilium](https://docs.cilium.io/)
