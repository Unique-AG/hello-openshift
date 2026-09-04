#!/usr/bin/env bash
# validate-instance.sh — confirm an environment is fully configured.
#
# Usage:
#   ./scripts/validate-instance.sh <env>
#
# Two checks, both of which catch a class of failure that is otherwise silent
# until something is already broken in the cluster:
#
#   1. No <TOKEN> placeholder survives anywhere in gitops/. A missed token is
#      why the template branch must never be deployed directly — a leftover
#      <DOMAIN_BASE> in a Route or an image reference fails at pull or ingress
#      time, not at render time.
#
#   2. No `unset_default_value` survives. defaults/ uses that marker for keys a
#      deployment MUST supply; it exists so a forgotten value is loud rather
#      than rendering as an empty string that a service accepts and then
#      misbehaves on.
#
# Exits non-zero on any finding, so it works as a CI gate and a pre-push check.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <env>" >&2
  exit 1
fi

ENV="$1"
ENV_DIR="gitops/environments/$ENV"
CONFIG="$ENV_DIR/instance-config.yaml"
STATE="$ENV_DIR/.instance-applied.yaml"
rc=0

[[ -d "$ENV_DIR" ]] || { echo "ERROR: no such environment: $ENV_DIR" >&2; exit 1; }

echo "== validating $ENV =="

# --- 1. instance-config present and filled in -------------------------------
if [[ ! -f "$CONFIG" ]]; then
  echo "FAIL  $CONFIG missing — copy gitops/instance-config.yaml.template"
  rc=1
else
  # Inspect VALUES only, never comments — the annotations in instance-config.yaml
  # legitimately discuss <TOKEN> placeholders, and a plain grep would flag those.
  if left=$(yq -r '.. | select(tag == "!!str")' "$CONFIG" 2>/dev/null | grep -E '^<[A-Z_]+>$' || true); [[ -n "$left" ]]; then
    echo "FAIL  $CONFIG still holds placeholder values:"
    echo "$left" | sort -u | sed 's/^/        /'
    rc=1
  else
    echo "ok    $CONFIG has no placeholder values"
  fi
fi

# --- 2. no placeholder token left in the rendered tree ----------------------
# The template branch legitimately contains them, so this is the check that
# distinguishes "template" from "deployable".
if hits=$(grep -rInE '<(GITHUB_REPO_URL|GIT_TARGET_REVISION|DOMAIN_[A-Z]+|CLUSTER_DOMAIN|APPS_DOMAIN|REGISTRY_[A-Z_]+|AWS_[A-Z_]+|CONNECTIVITY_ACCOUNT_ID|ACM_CERTIFICATE_ARN|ZITADEL_[A-Z_]+)>' \
      --exclude-dir=.git --exclude='instance-config.yaml.template' gitops/ 2>/dev/null); then
  echo "FAIL  placeholder tokens still present in gitops/:"
  echo "$hits" | sed 's/^/        /' | head -20
  rc=1
else
  echo "ok    no placeholder tokens in gitops/"
fi

# --- 3. no unset_default_value left ----------------------------------------
if hits=$(grep -rIn 'unset_default_value' --exclude-dir=.git gitops/ 2>/dev/null); then
  echo "FAIL  required values not supplied (unset_default_value):"
  echo "$hits" | sed 's/^/        /' | head -20
  rc=1
else
  echo "ok    no unset_default_value markers"
fi

# --- 4. applied state matches the config -----------------------------------
if [[ -f "$CONFIG" ]]; then
  if [[ ! -f "$STATE" ]]; then
    echo "WARN  $STATE missing — run ./scripts/configure-instance.sh $ENV"
  elif diff -q "$CONFIG" "$STATE" >/dev/null 2>&1; then
    echo "ok    applied state matches instance-config.yaml"
  else
    echo "FAIL  instance-config.yaml has changed since it was last applied:"
    diff "$CONFIG" "$STATE" | sed 's/^/        /' | head -20
    echo "        run ./scripts/configure-instance.sh $ENV"
    rc=1
  fi
fi

echo
[[ $rc -eq 0 ]] && echo "$ENV is fully configured." || echo "$ENV is NOT deployable — see failures above."
exit $rc
