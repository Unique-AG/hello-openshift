# Identity — sync wave 4

Zitadel, the OIDC provider every frontend and backend authenticates against.

| Piece | Where |
| --- | --- |
| Namespace and ServiceAccount | `gitops/components/identity/zitadel/` |
| ExternalSecret (database credential, masterkey) | `gitops/environments/<env>/identity/external-secret-zitadel.yaml` |
| Helm values | `gitops/environments/<env>/identity/values/zitadel.yaml` |
| Route | `gitops/environments/<env>/identity/route-zitadel.yaml` |
| Application | `gitops/environments/<env>/root/app-zitadel.yaml` (wave 5) |

The namespace and ServiceAccount are in wave 4 so they exist before the chart
Application runs in wave 5.

## The object IDs are the sharp edge

Zitadel mints numeric object IDs — project, root org, tenant org, SPA client —
when it is first configured. Eight Helm values files consume them, in twenty
places. **Every one of them changes when Zitadel is rebuilt.**

They are declared once in `gitops/environments/<env>/zitadel-ids.env` (created
from its `.template`) and propagated by `scripts/set-zitadel-ids.sh`, which
rewrites by key rather than by matching the old value, so it is idempotent from
any starting state.

Getting this wrong is expensive to diagnose. A backend left on the wrong
`ZITADEL_PROJECT_ID` reads the caller's roles from
`urn:zitadel:iam:org:project:${ZITADEL_PROJECT_ID}:roles`, finds nothing, and
denies the request with "Forbidden resource" — **inside an HTTP 200**, because
the GraphQL layer reports authorisation failures in the response body. The
service looks healthy from every angle except the user's.

Two further values are derived from Zitadel and are *not* covered by the script,
because they live in AWS Secrets Manager and must be refreshed by hand after a
rebuild:

- `<prefix>/chat-secrets` → `JWT_PUBLIC_KEY`, from the Zitadel JWKS
- `<prefix>/scope-management-secrets` → `ZITADEL_PAT`, an IAM_OWNER PAT

## Bootstrap credential

`FirstInstance` in the values file seeds the root org and its admin user. That
block applies **only on Zitadel's first start**; changing it later does nothing.

`PasswordChangeRequired: true` is set explicitly. It is not a Zitadel default —
the key is absent from upstream's `defaults.yaml`, so it takes the Go zero value
`false`, and without the line the seeded password would stay valid indefinitely.

## Registration is closed

`LoginPolicy.AllowRegister: false` — users are provisioned, not self-registered.
`IgnoreUnknownUsernames: true` keeps the login form from confirming which
addresses exist.
