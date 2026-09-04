#!/usr/bin/env bash
# configure-instance.sh — apply an environment's instance-config.yaml to the gitops tree.
#
# Usage:
#   ./scripts/configure-instance.sh <env>            # apply
#   ./scripts/configure-instance.sh <env> --check    # report drift, change nothing
#
# Requires: yq (https://github.com/mikefarah/yq), python3
#
# Replaces set-cluster-domain.sh and set-zitadel-ids.sh, which did the same job
# from two separate .env files.
#
# IDEMPOTENT, and safe from any starting state. The values currently stamped into
# the tree are recorded in <env>/.instance-applied.yaml; this script rewrites
# from those to the ones in <env>/instance-config.yaml. On a fresh clone of the
# template branch there is no state file, so it rewrites from the <TOKEN>
# placeholders instead. Either way it never guesses: it always knows the exact
# string it is replacing, so re-running is a no-op rather than a corruption.
#
# SCOPE: only files under gitops/ are rewritten.
#   - terraform/ has its own instance config (environments/*.tfvars), exactly as
#     hello-aws keeps layer config in *.auto.tfvars — not this script's business.
#   - scripts/ read instance-config.yaml directly with yq rather than being
#     stamped, so there is one less thing to keep in sync.
#
# NOTE for a second environment: this rewrites all of gitops/, including the
# shared bootstrap/ and components/ trees, because this repo has exactly one
# environment. Adding a second would first require moving the cluster-specific
# files out of those shared trees (today: bootstrap/cilium/values.yaml's
# k8sServiceHost and components/platform/harbor/*) into the env directory,
# otherwise configuring one environment would clobber the other.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <env> [--check]" >&2
  echo "  e.g. $0 sbx" >&2
  exit 1
fi

ENV="$1"
CHECK=0
[[ "${2:-}" == "--check" ]] && CHECK=1

ENV_DIR="gitops/environments/$ENV"
CONFIG="$ENV_DIR/instance-config.yaml"
STATE="$ENV_DIR/.instance-applied.yaml"

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required (brew install yq)" >&2; exit 1; }
[[ -d "$ENV_DIR" ]] || { echo "ERROR: no such environment: $ENV_DIR" >&2; exit 1; }
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: $CONFIG not found." >&2
  echo "  cp gitops/instance-config.yaml.template $CONFIG   # then fill it in" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The origin: what a fresh clone of the template branch contains.
# Must stay in step with gitops/instance-config.yaml.template.
# ---------------------------------------------------------------------------
origin_config() {
  cat <<'ORIGIN_EOF'
github:
  repoURL: "<GITHUB_REPO_URL>"
  targetRevision: "<GIT_TARGET_REVISION>"
domain:
  base: "<DOMAIN_BASE>"
  identity: "<DOMAIN_IDENTITY>"
cluster:
  domain: "<CLUSTER_DOMAIN>"
  appsDomain: "<APPS_DOMAIN>"
registry:
  host: "<REGISTRY_HOST>"
  uiHost: "<REGISTRY_UI_HOST>"
  project: uniquecr
aws:
  region: "<AWS_REGION>"
  accountId: "<AWS_ACCOUNT_ID>"
  connectivity:
    accountId: "<CONNECTIVITY_ACCOUNT_ID>"
  acm:
    certificateArn: "<ACM_CERTIFICATE_ARN>"
zitadel:
  projectId: "<ZITADEL_PROJECT_ID>"
  rootOrgId: "<ZITADEL_ROOT_ORG_ID>"
  orgId: "<ZITADEL_ORG_ID>"
  clientId: "<ZITADEL_CLIENT_ID>"
ORIGIN_EOF
}

# Every instance value, as a yq path. Derived values are computed below rather
# than listed here, so they cannot drift from the thing they derive from.
PATHS=(
  .github.repoURL
  .github.targetRevision
  .domain.base
  .domain.identity
  .cluster.domain
  .cluster.appsDomain
  .registry.host
  .registry.uiHost
  .aws.region
  .aws.accountId
  .aws.connectivity.accountId
  .aws.acm.certificateArn
  .zitadel.projectId
  .zitadel.rootOrgId
  .zitadel.orgId
  .zitadel.clientId
)

FROM_FILE=$(mktemp); TO_FILE="$CONFIG"; PAIRS=$(mktemp)
trap 'rm -f "$FROM_FILE" "$PAIRS"' EXIT

if [[ -f "$STATE" ]]; then
  cp "$STATE" "$FROM_FILE"
  echo "from: $STATE (previously applied)"
else
  origin_config > "$FROM_FILE"
  echo "from: <TOKEN> placeholders (no state file — fresh template clone)"
fi
echo "to:   $CONFIG"
echo

read_val() { yq -r "$1 // \"\"" "$2"; }

for p in "${PATHS[@]}"; do
  f=$(read_val "$p" "$FROM_FILE")
  t=$(read_val "$p" "$TO_FILE")
  if [[ -z "$t" ]]; then
    echo "ERROR: $CONFIG is missing $p" >&2
    exit 1
  fi
  [[ "$f" == "$t" ]] && continue
  # Short, common values must not be replaced bare. `targetRevision` is the word
  # "deploy", which appears 14 times across gitops/ but is only a value on the 4
  # `targetRevision:` lines — a blind replace would rewrite the prose.
  anchor=""
  [[ "$p" == ".github.targetRevision" ]] && anchor="targetRevision: "
  printf '%s\t%s\t%s\t%s\n' "$p" "$f" "$t" "$anchor" >> "$PAIRS"
done

# Derived: Zitadel's public issuer follows the identity host.
f_iss=$(read_val .domain.identity "$FROM_FILE"); t_iss=$(read_val .domain.identity "$TO_FILE")
if [[ "$f_iss" != "$t_iss" ]]; then
  printf '%s\t%s\t%s\t\n' "(derived) zitadel issuer" "https://$f_iss" "https://$t_iss" >> "$PAIRS"
fi
# Derived: the image registry prefix every image reference uses.
f_reg="$(read_val .registry.host "$FROM_FILE")/$(read_val .registry.project "$FROM_FILE")"
t_reg="$(read_val .registry.host "$TO_FILE")/$(read_val .registry.project "$TO_FILE")"
if [[ "$f_reg" != "$t_reg" ]]; then
  printf '%s\t%s\t%s\t\n' "(derived) registry prefix" "$f_reg" "$t_reg" >> "$PAIRS"
fi

if [[ ! -s "$PAIRS" ]]; then
  echo "Already up to date — nothing to change."
  exit 0
fi

echo "changes to apply:"
while IFS=$'\t' read -r p f t a; do printf '  %-32s %s%s -> %s%s\n' "$p" "$a" "$f" "$a" "$t"; done < "$PAIRS"
echo

# ---------------------------------------------------------------------------
# Apply. Longest source string first, so nested values cannot corrupt each
# other: registry.host CONTAINS domain.base, cluster.appsDomain CONTAINS
# cluster.domain, and registry.uiHost CONTAINS cluster.appsDomain. Replacing
# the short one first would leave the long ones half-rewritten.
# ---------------------------------------------------------------------------
rc=0
if ! CHECK=$CHECK PAIRS="$PAIRS" python3 - <<'PY'
import os, pathlib, sys

check = os.environ["CHECK"] == "1"
pairs = []
for line in open(os.environ["PAIRS"]):
    parts = line.rstrip("\n").split("\t")
    _, frm, to = parts[0], parts[1], parts[2]
    anchor = parts[3] if len(parts) > 3 else ""
    if frm and frm != to:
        pairs.append((anchor + frm, anchor + to))
pairs.sort(key=lambda p: len(p[0]), reverse=True)

skip_names = {"instance-config.yaml", ".instance-applied.yaml"}
changed, total = [], 0
for path in sorted(pathlib.Path("gitops").rglob("*")):
    if not path.is_file() or path.name in skip_names:
        continue
    # Template files legitimately hold the <TOKEN> placeholders and are the
    # source the tokens come FROM — stamping them would erase the template.
    if path.suffix == ".template":
        continue
    try:
        original = path.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    text = original
    hits = 0
    for frm, to in pairs:
        n = text.count(frm)
        if n:
            text = text.replace(frm, to)
            hits += n
    if hits:
        changed.append((str(path), hits))
        total += hits
        if not check:
            path.write_text(text)

for p, n in changed:
    print(f"  {'would rewrite' if check else 'rewrote'} {p}  ({n})")
print()
verb = "would change" if check else "changed"
print(f"{verb} {total} occurrence(s) across {len(changed)} file(s)")
sys.exit(1 if (check and changed) else 0)
PY
then rc=$?
fi

if [[ $CHECK -eq 1 ]]; then
  [[ $rc -eq 0 ]] && echo "in sync." || echo "DRIFT — run without --check to apply."
  exit $rc
fi

cp "$CONFIG" "$STATE"
echo
echo "state recorded in $STATE"
echo "next: ./scripts/validate-instance.sh $ENV"
