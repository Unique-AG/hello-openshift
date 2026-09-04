# Release Concept

How a Unique platform release becomes a running deployment in your copy of
`hello-openshift`, and how you keep an environment up to date over time.

This is the OpenShift sibling of the model described in
[hello-aws](https://github.com/Unique-AG/hello-aws/blob/main/docs/release-concept.md).
The branching model is the same; the delivery mechanics differ, because here
everything inside the cluster is owned by ArgoCD and the AWS substrate is a much
smaller surface.

`hello-openshift` is **trunk-based**. One `main` branch is the source of truth
and the environment template; one long-lived **`deploy`** branch is what ArgoCD
actually tracks. Updates flow **forward only** (`main` → `deploy`).

---

## At a glance

| | |
|---|---|
| **Trunk** | `main` — source of truth and environment template; CI-gated; carries chart versions and environment-agnostic bases, no live cluster values |
| **Deploy branch** | `deploy` — what every ArgoCD Application tracks (`targetRevision: deploy`). Pushing here reconciles the cluster |
| **Release** | a Git tag `202X.XX.X` on `main` naming a complete set of chart versions and configuration |
| **Flow direction** | always forward: `feat/*` → `main` → `deploy`. Never `deploy` → `main` |
| **Infrastructure** | Terraform, three stacks, applied **by hand** via the Makefile — not by CI |
| **In-cluster** | one ArgoCD ApplicationSet generating an Application per spec in `apps/`, reconciled automatically from `deploy` |
| **What varies** | **version**, **release config** and **instance config**, each with its own home |

---

## Branching model

```
feat/* ─┐
fix/*  ─┤ squash PR (CI gates — see Quality gates)
chore/*┘
        ▼
      main ──tag 202X.XX.X──►  trunk + environment template
        │
        │  adopt a release = merge it forward into deploy
        ▼
      deploy ──push──►  ArgoCD reconciles the cluster
                        (Terraform is applied separately, by hand)
```

### `main` — trunk and environment template

All work lands via squash-merged PRs, and CI gates every one. `main` carries the
chart versions, the environment-agnostic bases under `gitops/components/`, and
the Terraform. It holds no live cluster identity: the cluster domain and the
Zitadel object IDs live in gitignored files created from `.template`.

### `deploy` — the deployment branch

The ApplicationSet in `gitops/environments/<env>/argo/` points at
`targetRevision: deploy`, so **a push to `deploy` is a deployment** for
everything inside the cluster. The git reference is stated once, there, rather
than repeated on every Application. The branch diverges forward from `main` and
is never merged back.

A fresh clone has no `deploy` branch. Create it before bootstrapping ArgoCD, or
every Application fails to resolve its source:

```bash
git switch -c deploy main && git push -u origin deploy
```

### Feature branches

`feat/*`, `fix/*`, `chore/*` → PR → squash-merge to `main`. PRs validate only;
nothing is applied from a PR.

---

## The two delivery tracks

A release reaches a cluster by two independent mechanisms — and unlike
`hello-aws`, only one of them is automated.

### Track 1 — Infrastructure: Terraform, applied by hand

```
0-bootstrap → 1-foundation → 2-cluster
```

Applied with the Makefile from a workstation with AWS credentials:

```bash
make init apply STACK=1-foundation ENV=sbx
```

There is deliberately **no deploy workflow in this repository.** Applying the
cluster stack takes 40–60 minutes, the ROSA cluster itself is created out of
band with `rosa create cluster --no-cni` and imported (see
[`terraform/2-cluster/README.md`](../terraform/2-cluster/README.md)), and the
Red Hat service-account credentials are supplied per-run as environment
variables. A pipeline that auto-applied on push would be claiming an automation
this repository does not have. CI validates; humans apply.

### Track 2 — In-cluster: ArgoCD

ArgoCD watches `deploy`. One ApplicationSet
(`gitops/environments/<env>/argo/appsets.yaml`) generates an Application per
spec in `gitops/environments/<env>/apps/`, ordered by sync wave. This is fully
automatic: merge to `deploy`, and the cluster follows.

An app spec carries only what differs between apps — name, namespace, wave and
chart pins — in one of three source shapes:

| Key | Meaning |
|---|---|
| `path` | a kustomize directory in this repo; the ApplicationSet supplies repo + revision |
| `sources` | one or more charts; the ApplicationSet appends the `ref: values` git source |
| `source` | a single chart needing no `$values` ref (inline `valuesObject`) |

with optional `prune`, `syncOptions` and `ignoreDifferences` overrides.
Everything else — project, destination server, sync options, retry backoff — is
declared once in the ApplicationSet. Adding an app is dropping a file in
`apps/`; there is nothing to register.

The AppProject, the OCI repo credential and the ApplicationSet itself are the
only ArgoCD objects that are **not** self-healing, and are applied by hand once
per cluster with `oc apply -k gitops/bootstrap/envs/<env>`. The AppProject has
to exist before any Application in it can sync, so it cannot be managed by an
Application inside that project.

The waves matter and are load-bearing; see the table in the
[README](../README.md#gitops-layers).

---

## Separating version, release config, and instance config

Three kinds of content kept strictly apart, each changing for its own reason.

| Concern | Examples | Changes when… | Lives in | On |
|---|---|---|---|---|
| **Version** | Helm chart version, image tag | a new Unique **release** | `gitops/environments/<env>/apps/*.yaml` | `main`, at each release tag |
| **Release config** | feature-flag defaults, env-var wiring, resource defaults | a new **release** | the per-app chart itself, shipped by Unique | — (arrives with the chart version) |
| **Instance config** | cluster domain, Zitadel IDs, account id, registry host, ACM ARN, per-env sizing | a new **environment or cluster** | `gitops/environments/<env>/instance-config.yaml` and `value-overlays/`, plus `environments/<env>/*.tfvars` | `deploy` |

> **There is no `defaults/` directory here, deliberately.** `hello-aws` needs
> one because its charts are generic — a single `backend-service` chart serves
> about a dozen services, so the per-service wiring has to live somewhere. This
> repository uses **per-app charts** (`helm/chat`, `helm/admin-app`, …) at the
> release version, and the chart *is* the release-config layer, shipped and
> versioned by Unique. A `defaults/` tree would hold only duplication and imply
> a separation that does not exist. `value-overlays/` are exactly what the name
> says: overrides on top of the chart's own defaults.
>
> The practical consequence: adopting a release changes version pins in `apps/`
> and, occasionally, one overlay. It never involves merging a `defaults/` folder.

The rule for deciding where something belongs: **if it would still be true on
another cluster, it is release content; if it names this cluster, it is instance
config.** Anything under `gitops/components/` must build for any environment —
where a base object needs one environment-specific field, that field is patched
from the overlay rather than baked in.

---

## Release identity and versioning

- **Release version** — a Git tag `202X.XX.X` on `main`, matching the Unique
  platform release it pins. See the
  [Unique Release Notes & Calendar](https://docs.unique.ai/it-operators/installing-and-upgrading-unique/release-notes-and-calendar)
  for what each version changes and any newly-required configuration.
- **Component versions** — the `targetRevision` on each Unique chart
  Application. Diff two releases with
  `git diff 202X.21.0 202X.22.0 -- gitops/environments/sbx/root`.
- **OpenShift version** — pinned to a full patch in
  `environments/<env>/2-cluster.tfvars`. Pinning only the minor is unsafe here:
  the version list the OCM API returns is unordered, so a bare `"4.19"` resolves
  to an arbitrary patch and silently drifts.
- **Resource traceability** — Terraform stamps `semantic_version` from
  `environments/common.tfvars` onto the resources it manages, so an AWS resource
  traces back to the configuration version that created it.
- **Image registry** — image *tags* are version content; the *registry* host is
  instance config (`registry.host`), propagated by
  `scripts/configure-instance.sh`.
- **Diffing two releases** — `git diff 202X.21.0 202X.22.0 -- gitops/environments/sbx/apps`.

---

## How a release flows

1. **Cut on `main`** — bump `targetRevision` on the affected Applications,
   update any newly-required configuration in `gitops/components/` or the
   `value-overlays/` files, and bump Terraform provider versions if the release
   needs it. **Render every chart against your own values before pushing** —
   2026.34 shipped `configuration`'s `extraRoutes.notifications-optout` enabled
   by default, which hard-fails without the Gateway API CRDs this cluster does
   not have. Open a PR; CI gates it; squash-merge.
2. **Tag** — tag the merge commit `202X.XX.X`.
3. **Adopt** — merge the tag forward into `deploy` and supply any new instance
   values. Push.
4. **Apply infrastructure if the release changed it** — `make apply` per stack,
   in order. Most application releases change nothing here.
5. **Verify** — `scripts/smoke-test.sh`.

---

## Runbook

### Part A — Cut the release (on `main`)

1. Review the target Unique release for infrastructure-relevant changes: new or
   newly-required environment variables, feature flags, dependency upgrades.
2. Branch from `main`: `chore/release-202X.XX`.
3. Bump `targetRevision` on the affected chart Applications.
4. Add newly-*required* configuration; leave optional settings out.
5. Open a PR to `main`; CI must be green.
6. Squash-merge and tag `202X.XX.X`.

### Part B — Adopt the release (on `deploy`)

1. Merge the tag into `deploy`. Supply any new instance values under
   `gitops/environments/<env>/`.
2. Push. ArgoCD shows the affected Applications OutOfSync; review each diff —
   it should contain version bumps and new release config only — then let them
   sync and wait for Healthy.
3. If the release changed Terraform, apply the affected stacks by hand.

### Part C — Verify

```bash
scripts/smoke-test.sh
```

Then end to end: sign in, open a space, send a chat message, upload a document,
and ask a question that requires retrieval.

### Part D — Rollback

- **Applications** — re-point `targetRevision` to the previous version and
  sync, or roll back in ArgoCD. **Schema migrations are forward-only**: a
  version revert runs older code against a newer database schema, so prefer
  fixing forward for any service that ran a migration.
- **Infrastructure** — revert and re-apply. Some changes are not reversible in
  place; plan data-tier rollbacks deliberately.
- **The cluster stack** is the exception: destroying and rebuilding `2-cluster`
  invalidates the CloudNativePG credentials and changes the cluster domain. Both
  have propagation paths (`sync-db-passwords.sh`, and `cluster.domain` in
  `instance-config.yaml` applied with `configure-instance.sh`) — use them before
  concluding anything is broken.

---

## Consuming releases in your own copy

Self-hosting means maintaining your **own private copy** of this repository — it
will carry your domains, account id and identity configuration — while tracking
the public repository as an upstream to pull releases from.

### Why not a GitHub "Fork"

A GitHub fork of a public repository is itself public and **cannot be made
private**, so it is unsuitable. Create a private repository and add this one as
an `upstream` remote:

```bash
# 1. Mirror upstream into your new empty PRIVATE repo
git clone --bare https://github.com/Unique-AG/hello-openshift.git
git -C hello-openshift.git push --mirror <your-private-repo-url>

# 2. Clone yours and track the public upstream
git clone <your-private-repo-url> && cd <your-repo>
git remote add upstream https://github.com/Unique-AG/hello-openshift.git
git fetch upstream --tags
```

### Adopt a release

```bash
git fetch upstream --tags
git switch main && git merge 202X.XX.X     # bring the release onto your trunk
git switch deploy && git merge main        # adopt it in the environment
git push
```

Your instance config lives on `deploy` and in gitignored files, so it survives
the merge. Resolve conflicts in favour of upstream for release content, and in
favour of yours for anything naming your cluster.
