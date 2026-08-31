# Chat — sync waves 5 and 6

The Unique application slice: three frontends and seven backends. This layer
holds only what is environment-agnostic — the namespace and its SCC bindings.
Everything with a version or a value in it is per-environment.

| Piece | Where |
| --- | --- |
| Namespace, SCC bindings | `gitops/components/chat/` (wave 5) |
| ExternalSecrets (db, redis, rabbitmq, app secrets) | `gitops/environments/<env>/chat/external-secret-*.yaml` |
| Helm values | `gitops/environments/<env>/chat/values/*.yaml` |
| Routes | `gitops/environments/<env>/chat/route*.yaml` |
| Applications | `gitops/environments/<env>/root/app-*.yaml` (wave 6) |

See [`gitops/environments/sbx/chat/README.md`](../../environments/sbx/chat/README.md)
for the per-service breakdown, chart versions, and what was changed relative to
the upstream reference deployment.

## Why the namespace is a wave earlier than the workloads

The frontends and backends are wave 6; this namespace and its SCC bindings are
wave 5. OpenShift admits a pod against the SCCs bound at admission time, so a
workload scheduled before its SCC binding exists is rejected — and unlike a
missing CRD, the failure surfaces as a pod that will not start rather than as a
sync error.

## Images come from Harbor, not the upstream registry

Every `registry:` in the values files points at the in-cluster Harbor
proxy-cache host, not at the Unique ACR directly. Harbor's registry endpoint is
deliberately kept **off** the cluster apps domain — it resolves through a
Route53 private zone to an internal ELB — so it survives a cluster rebuild and
the image references never need rewriting.

`scripts/set-cluster-domain.sh` owns those `registry:` lines. `scripts/setup-harbor-projects.sh`
creates the proxy-cache projects they resolve through.

## Auth

All ten services resolve roles against Zitadel. The four object IDs they consume
are propagated by `scripts/set-zitadel-ids.sh` — see
[`../identity/README.md`](../identity/README.md) for why a stale one is
particularly hard to diagnose.
