# Conduct dependencies

GitOps definitions for the Conduct stack's dependencies, mirroring Unique's
internal QA environment with the Azure-specific pieces trimmed for this
AWS/OpenShift sandbox. Where a choice below differs from QA, the reason is
noted.

## Layout

| Piece | Where |
| --- | --- |
| Namespaces (`system`, `sbx`, `eventing`, `finance-gpt`) | `gitops/components/conduct/{agent-sandbox,rabbitmq,qdrant}/` (synced by the `conduct` app, wave 4) |
| ExternalSecrets (RabbitMQ credentials, LiteLLM env) | `gitops/environments/sbx/conduct/external-secret-*.yaml` (wave 4) |
| Helm values | `gitops/environments/sbx/conduct/values/*.yaml` (referenced via `$values`) |
| Applications | `gitops/environments/sbx/apps/{rabbitmq,qdrant,litellm,agent-sandbox-controller}.yaml` (wave 5) |

## Services and pinned chart versions

| Service | Namespace (as in QA) | Chart | Version pin |
| --- | --- | --- | --- |
| RabbitMQ | `eventing` | `rabbitmq` from `https://charts.bitnami.com/bitnami` | `16.0.14` |
| Qdrant | `finance-gpt` | `qdrant` from `https://qdrant.github.io/qdrant-helm` | `1.18.2` (QA pins its ACR mirror by digest, comment `1.18.2`) |
| LiteLLM | `system` (QA's default destination) | `oci://ghcr.io/berriai/litellm-helm` | digest `sha256:df9be29316b0eda2b7df5ba6077a39aeb818cf20fb19b01ea4bd8937af1063b3` = tag `1.90.2`, verified on public ghcr.io |
| LiteLLM cache Redis | `system` | `redis` from `https://ot-container-kit.github.io/helm-charts` (Opstree) | `0.16.9` (QA pins its ACR mirror by digest) |
| agent-sandbox controller | `system` | `oci://ghcr.io/unique-ag/helm-charts/agent-sandbox-controller` | digest `sha256:d7f42ba093aaae96807af6a6af7e71f3d2f5cf0a802e5f194745ef379e466d80` = tag `0.4.5-rc.1`, verified on ghcr.io |

The `oci://` sources require ArgoCD >= 3.1 (native OCI support) — QA runs the
same pattern.

## Required AWS Secrets Manager secrets

Created out-of-band (terraform/1-foundation or manually), consumed through the
`aws-secrets-manager` ClusterSecretStore:

| ASM key | Properties | Consumed by |
| --- | --- | --- |
| `hello-openshift/sbx/rabbitmq` | `username` (**must be `admin`** — the bitnami chart hardcodes `auth.username` and it must match), `password`, `erlangCookie`, `consumerUsername`, `consumerPassword` | `rabbitmq-admin-credentials` + `rabbitmq-load-definition` ExternalSecrets in `eventing` |
| `hello-openshift/sbx/litellm` | `DATABASE_URL` (postgres DSN, e.g. pointing at the CNPG cluster in `hello-openshift-data`), `PROXY_MASTER_KEY` (`sk-...`), `ANTHROPIC_API_KEY` | `litellm` ExternalSecret in `system` |

Qdrant and the agent-sandbox controller need no secrets (QA runs Qdrant
unauthenticated behind network policies).

## sbx-gateway: NOT implemented

The sbx-gateway (the MITM egress proxy for sandboxes) is deliberately absent:
its image lives in the private `uniqueapp.azurecr.io` ACR and there is no
public substitute. Deploying it here first needs registry credentials for that
ACR (an image pull secret + AppProject/source wiring). Until then, sandbox
egress runs without the MITM proxy.

## Skipped / substituted vs QA

- **Tailscale ingress** (RabbitMQ management UI, Qdrant, LiteLLM
  `*.<tailnet>.ts.net` hosts + `PROXY_BASE_URL`): skipped — no Tailscale
  operator here.
- **ACR-mirrored images/charts** (`uniqueapp.azurecr.io/...`) and the
  `image-pull-secret-v2026.05` pull secret: substituted with the public
  upstream registries (docker.io `bitnamilegacy/rabbitmq`, qdrant
  `-unprivileged` image, ghcr.io `berriai/litellm-database`, quay.io
  `opstree/redis*`). QA's *image* digest pins were dropped where they refer to
  the mirror; *chart* digest pins were kept where they resolve publicly.
- **Azure workload identity + GCP Vertex WIF** (LiteLLM pod labels, SA
  annotations, `gcp-wif` volumes, `enable_azure_ad_token_refresh`,
  `VERTEXAI_PROJECT`): skipped — no such federation on this cluster.
- **litellm-extras chart** (Azure Key Vault SecretStore, viewer-user job,
  CiliumNetworkPolicy, alerts, dashboard) and **qdrant-extras chart**
  (CiliumNetworkPolicy, alerts, dashboard): skipped — they live in the private
  `Unique-AG/infrastructure` repo. The one required piece (the `litellm`
  secret) is replaced by an ExternalSecret from AWS Secrets Manager.
- **QA model_list** (60+ models incl. Azure OpenAI deployments, from the
  private monorepo value-overlay): trimmed to three public-API Anthropic
  models; extend `values/litellm.yaml` as needed.
- **RabbitMQ `ClusterExternalSecret` fan-out** to consumer namespaces (`bot`,
  `python`, ...) and the `rabbitmq-cluster-service-binding` secret: replaced
  by plain ExternalSecrets in `eventing` — the consumer namespaces don't exist
  here yet.
- **KEDA `ClusterTriggerAuthentication`** (rabbitmq-http/amqp): skipped — KEDA
  is not installed.
- **CiliumNetworkPolicies** (RabbitMQ, router ingress allow-list): skipped —
  they whitelist QA workloads (`node-*`, `assistants-core`) that don't exist
  here; the router NetworkPolicy additionally hardcodes DNS egress to
  `kube-system/kube-dns`, which doesn't exist on OpenShift. Add policies when
  consumers land.
- **Sizing**: Qdrant runs 1 replica / 20Gi `gp3-csi` (QA: "large" preset — 4
  replicas, 8Gi, 100Gi ZRS); LiteLLM runs 1 replica (QA: 2); `priorityClassName:
  unique-critical` dropped (class doesn't exist here).
- **OpenShift SCC**: fixed UIDs/fsGroups from chart defaults are removed
  (bitnami `*SecurityContext.enabled: false`, `null` overrides elsewhere) so
  the `restricted-v2` SCC can assign namespace-range IDs.
- **LiteLLM `prometheus_metrics_config`** allowlist: skipped (QA
  metric-cardinality tuning).
