# Unique chat slice (sbx)

Serves the Unique chat UI at `https://openshift.example.com/chat`.

## What this deploys

Root Applications (`gitops/environments/sbx/root/`), all pulling per-app charts
from `oci://uniquecr.azurecr.io/helm/*:2026.37.0` via the ArgoCD OCI repo
credential (`external-secret-argocd-uniquecr.yaml`, ESO ← ASM
`hello-openshift/sbx/acr-pull`):

| App | Chart | Role | Namespace |
|-----|-------|------|-----------|
| `web-app-chat` | `chat-app` | chat frontend (served at `/chat`) | `unique` |
| `backend-service-chat` | `chat` | node-chat backend | `unique` |
| `unique-api` | `unique-api` | public-API forwarding target for node-chat (mandatory from 2026.36) | `unique` |
| `backend-service-app-repository` | `app-repository` | app repo backend | `unique` |
| `assistants-core` | `assistants-core` | AI / sandbox orchestrator | `unique` |
| `chat` (infra) | this dir | ns, SCC, Route, ExternalSecrets | `unique` |

Wiring: CNPG Postgres (`chat` / `app_repository` DBs, structured `DATABASE_URL`
from the `chat-db` ExternalSecret), RabbitMQ (`eventing`), data-services Redis,
LiteLLM (`system`). Kong/Gateway-API routes are disabled (no Gateway API on this
cluster); exposure is the OpenShift `Route`.

## Blockers requiring user authorization

These two are cloud/cluster mutations the agent could not self-authorize.

### 1. Worker-node ECR pull permission (blocks ALL chat pods — ImagePullBackOff)

The ROSA `HCP-ROSA-Worker` role has no ECR permission, so kubelet can't pull
the pull-through-cache images. Fix committed as
`terraform/2-cluster/ecr-worker-iam.tf` — apply it:

```
cd terraform/2-cluster && AWS_PROFILE=hello-openshift-sbx terraform apply
```

(or, to unblock immediately, attach the same inline policy to
`rosa-uq-openshift-sbx-HCP-ROSA-Worker-Role` by hand.)

### 2. Ingress namespace ownership (blocks the /chat Route — HostAlreadyClaimed)

`openshift.example.com` is already claimed by the `hubble-ui` Route in the
`cilium` namespace. The default IngressController uses `Strict` namespace
ownership, so the `chat` Route in `unique` is rejected. To let one host serve
path-based apps across namespaces:

```
oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
  -p '{"spec":{"routeAdmission":{"namespaceOwnership":"InterNamespaceAllowed"}}}'
```

### 3. App secrets for the backends (chat + assistants-core Degraded)

`backend-service-chat` and `assistants-core` mount `extraEnvSecrets`
(`chat-secrets`, `assistants-core-secrets`) that carry non-derivable secrets.
Create the ASM secrets (keys documented in
`external-secret-app-secrets.yaml`), then ESO materializes them. The chat
backend additionally needs a running `configuration-backend` (not part of this
slice) — it reads `CONFIGURATION_BACKEND_URL` at boot.

External `/chat-api`, `/apps`, etc. routing for the backends assumes a separate
api host, which does not exist yet on the single CloudFront origin — the
frontend serves regardless; browser API calls are the follow-up.
