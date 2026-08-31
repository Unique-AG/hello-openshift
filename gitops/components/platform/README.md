# Platform — sync wave 2

The cluster-wide substrate everything else assumes: namespaces, the secret
bridge, the container registry, the CNI's in-cluster objects, and the sandboxing
runtime.

## Contents

| Piece | What it does |
| --- | --- |
| `namespaces/` | The platform namespaces (`hello-openshift-system`, `-data`, `-monitoring`, `external-secrets`) with their pod-security labels |
| `external-secrets/` | The `ClusterSecretStore` pointing at AWS Secrets Manager, and the operator config that gives the controller its IRSA role |
| `harbor/` | Namespace, object-bucket claim for the registry's storage, both ExternalSecrets, the non-root SCC binding, and the internal ELB Service |
| `object-storage/` | The `StorageCluster` running NooBaa in standalone mode (`multiCloudGateway.reconcileStrategy: standalone`) |
| `cilium/` | Namespace and SCC bindings for the CNI installed at bootstrap |
| `kata/` | `KataConfig`, the RuntimeClass alias, and stub CRDs |

## Why these are one layer

Everything here is a precondition for wave 3 and beyond. External Secrets must
be able to reach Secrets Manager before any workload asks for a credential;
Harbor's bucket must exist before its chart starts; the namespaces must exist
before anything is placed in them.

## Cilium is installed *before* this layer, not by it

The `cilium/` directory holds only the namespace and SCC bindings. The CNI
itself is installed by `gitops/bootstrap/cilium` as a hand-applied step, because
the cluster is created with `--no-cni` and has no working datapath until Cilium
runs. A cluster that reaches this layer without that step has every node
NotReady.

One consequence: the `network` cluster-operator stays permanently Degraded,
because multus crash-loops when nothing populates `/run/multus/cni/net.d`.
Cilium carries the datapath, and `scripts/smoke-test.sh` treats that single
degradation as expected.

## Kata needs stub CRDs

`mco-stub-crds.yaml` exists because the sandboxed-containers operator expects
the Machine Config Operator's CRDs, and ROSA HCP does not expose the MCO for
worker nodes. The stubs satisfy the operator's watches without pretending to
provide machine configuration.

## Environment-specific values

Nothing here names a cluster. Two fields that would are patched from the
environment overlay instead:

- the External Secrets controller's IRSA role ARN
- the Harbor registry ELB's ACM certificate ARN

Harbor's Route — whose host carries the cluster apps domain and changes on every
rebuild — is not in this layer at all; it lives in
`gitops/environments/<env>/platform/route-harbor.yaml` and is rewritten by
`scripts/set-cluster-domain.sh`.
