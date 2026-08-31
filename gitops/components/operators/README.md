# Operators — sync wave 1

Every OLM Subscription the platform depends on. This layer installs *operators*,
never their custom resources: the CRDs an operator ships must be Established
before anything references them, which is why the resources themselves live one
wave later.

## Subscriptions

| Operator | Package | Channel | Catalog | Provides |
| --- | --- | --- | --- | --- |
| External Secrets | `external-secrets-operator` | `stable` | `community-operators` | `ExternalSecret`, `ClusterSecretStore` — the AWS Secrets Manager bridge |
| CloudNativePG | `cloudnative-pg` | `stable-v1` | `certified-operators` | `Cluster`, `Database` — PostgreSQL, replacing Aurora |
| Redis (Opstree) | `redis-operator` | `stable` | `community-operators` | `RedisReplication`, `RedisSentinel` — replacing ElastiCache |
| ODF | `odf-operator` | `stable-4.19` | `redhat-operators` | `StorageCluster`, `ObjectBucketClaim` — NooBaa object storage, replacing S3 |
| MinIO | `minio-operator` | `stable` | `community-operators` | `Tenant` |
| Sandboxed containers | `sandboxed-containers-operator` | `stable` | `redhat-operators` | `KataConfig` — Kata/peer-pods for untrusted workloads |

All subscriptions use `installPlanApproval: Automatic`. The ODF and sandboxed
containers operators additionally need their own namespace and OperatorGroup,
which are defined alongside their subscription; the rest install into the
cluster-wide operator namespace.

The Redis operator also gets explicit RBAC (`rbac.yaml`): the community build
does not ship everything it needs to watch its own custom resources on
OpenShift.

## Ordering

This layer shares wave 1 with Cilium, and everything else waits for it. The
constraint is not politeness — a `Cluster` applied before the CloudNativePG CRD
exists is rejected outright, and ArgoCD reports the whole application as failed
rather than retrying indefinitely.

Cilium is in the same wave because it must own the datapath before any workload
schedules; see [`../platform/README.md`](../platform/README.md).

## Adding an operator

1. Add `gitops/components/operators/<name>/` with a `subscription.yaml` and a
   `kustomization.yaml`. Add a `namespace.yaml` and `operatorgroup.yaml` only if
   the operator requires its own namespace.
2. Reference it from `gitops/environments/<env>/operators/kustomization.yaml`.
3. Put its custom resources in a later wave, never here.
