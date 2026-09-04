# Cluster Bootstrap

The only hand-applied step per cluster. Everything after this is
ArgoCD's job: the root Application creates the AppProject and the
child Applications (operators → platform → data-services).

Requires cluster-admin on a freshly provisioned ROSA cluster
(`make apply STACK=2-cluster`).

ArgoCD tracks the **`deploy` branch** (the repo is private; Applications
use the SSH URL). Promote changes by merging/fast-forwarding `deploy`.

```bash
# 0. CNI FIRST (cluster is created --no-cni; nodes are NotReady until
#    Cilium runs). Values are the same file the cilium Application uses.
helm repo add cilium https://helm.cilium.io && helm repo update cilium
oc apply -k gitops/components/platform/cilium   # namespace + SCC grants
helm template cilium cilium/cilium --version 1.18.9 \
  --namespace cilium -f gitops/bootstrap/cilium/values.yaml \
  | oc apply --server-side -f -
oc -n cilium rollout status ds/cilium --timeout=600s

# 1. GitOps operator + ArgoCD instance config
#    (the ArgoCD CR apply may need a retry until the operator has
#    installed the CRD — re-run the same command)
oc apply -k gitops/bootstrap

# 2. Wait for ArgoCD to be up
oc wait --for=condition=Established crd/applications.argoproj.io --timeout=300s
oc -n openshift-gitops rollout status deploy/openshift-gitops-server

# 3. Repo credential: the read-only deploy key (private half lives in
#    gitignored .specs/argocd-deploy-key; public half is registered as
#    a GitHub deploy key). ArgoCD needs this BEFORE the first sync.
oc -n openshift-gitops create secret generic repo-hello-openshift \
  --from-literal=type=git \
  --from-literal=url=<GITHUB_REPO_URL> \
  --from-file=sshPrivateKey=.specs/argocd-deploy-key
oc -n openshift-gitops label secret repo-hello-openshift \
  argocd.argoproj.io/secret-type=repository

# 4. Seed the environment's root app-of-apps
oc apply -k gitops/bootstrap/envs/sbx
```

Watch convergence:

```bash
oc -n openshift-gitops get applications
```

## Verify-before-first-bootstrap checklist

These facts cannot be pinned offline; confirm them against the live
cluster/catalog once, then commit the pins:

- **GitOps operator channel**: `oc get packagemanifest openshift-gitops-operator -o jsonpath='{.status.channels[*].name}'` — replace `channel: latest` in `bootstrap/operator/subscription.yaml` with the current `gitops-1.x`.
- **Community operator channels/CSVs**: `oc get packagemanifests -n openshift-marketplace postgres-operator redis-operator minio-operator external-secrets-operator` — confirm `stable` is right, note `currentCSV` for future Manual-approval envs.
- **Opstree Redis CR API**: confirm the catalog CSV supports `redis.redis.opstreelabs.in/v1beta2` and the `v7.4.x` image tags.
- **MinIO image**: bump `components/data-services/minio/tenant.yaml` to the latest `quay.io/minio/minio` release.
- **ESO OperatorConfig**: confirm `spec.serviceAccount.annotations` propagates the IRSA annotation (`oc -n external-secrets get sa external-secrets -o yaml` after the platform app syncs); if not, patch the ServiceAccount directly in the platform overlay.
