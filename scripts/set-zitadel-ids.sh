#!/usr/bin/env bash
#
# Propagate this environment's Zitadel identifiers into every Helm values file.
#
# Why this exists: the four IDs appear as literals in 20 places across eight
# values files, and all of them change when Zitadel is rebuilt. In July four
# backends were left on the reference deployment's placeholder project id, which made every
# authenticated request fail with "Forbidden resource" carried inside an HTTP 200
# — invisible to any status-code check. This script removes that failure mode.
#
# It rewrites by KEY, never by old value, so it is idempotent and works from any
# starting state (including a fresh clone or a half-patched tree).
#
# Usage:
#   scripts/set-zitadel-ids.sh                       # values from zitadel-ids.env
#   scripts/set-zitadel-ids.sh --check               # verify only, exit 1 on drift
#   scripts/set-zitadel-ids.sh --env-file <path>
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/gitops/environments/sbx/zitadel-ids.env"
VALUES_DIR="$REPO_ROOT/gitops/environments/sbx/chat/values"
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    CHECK_ONLY=1; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$ENV_FILE" ] || { echo "!! env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

# Every ID must be present and look like a Zitadel snowflake, so a typo or an
# unsubstituted placeholder fails loudly instead of being written to 20 places.
for var in ZITADEL_PROJECT_ID ZITADEL_ROOT_ORG_ID ZITADEL_ORG_ID ZITADEL_CLIENT_ID; do
  val="${!var:-}"
  [ -n "$val" ] || { echo "!! $var is empty in $ENV_FILE" >&2; exit 1; }
  case "$val" in
    *[!0-9]*) echo "!! $var is not numeric: '$val' (Zitadel ids are numeric)" >&2; exit 1 ;;
  esac
  [ "${#val}" -ge 15 ] || { echo "!! $var looks too short to be a Zitadel id: '$val'" >&2; exit 1; }
done

# file -> the keys it carries. Backends resolve roles against the project and
# need the root org; the three frontends additionally need the tenant org and
# the SPA client id.
BACKEND_FILES="app-repository.yaml backend-service-chat.yaml configuration.yaml ingestion.yaml scope-management.yaml"
FRONTEND_FILES="web-app-chat.yaml web-app-admin.yaml web-app-knowledge-upload.yaml"
# assistants-core carries only the project id
PROJECT_ONLY_FILES="assistants-core.yaml"

changed=0; drift=0

set_key() {  # <file> <key> <value>
  local f="$1" k="$2" v="$3" cur
  [ -f "$f" ] || { echo "  !! missing file: ${f#"$REPO_ROOT"/}" >&2; return 1; }
  grep -qE "^[[:space:]]*$k:" "$f" || return 0          # key not used in this file
  cur="$(sed -nE "s/^[[:space:]]*$k:[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\1/p" "$f" | head -1)"
  [ "$cur" = "$v" ] && return 0
  if [ "$CHECK_ONLY" -eq 1 ]; then
    printf '  DRIFT %-32s %-22s %s -> %s\n' "$(basename "$f")" "$k" "$cur" "$v"
    drift=$((drift+1)); return 0
  fi
  # keep the original quoting style: these are numeric ids that MUST stay strings
  sed -i.bak -E "s|^([[:space:]]*)$k:[[:space:]]*.*$|\1$k: \"$v\"|" "$f"
  rm -f "$f.bak"
  printf '  set   %-32s %-22s %s -> %s\n' "$(basename "$f")" "$k" "$cur" "$v"
  changed=$((changed+1))
}

echo "Zitadel ids from ${ENV_FILE#"$REPO_ROOT"/}:"
printf '  project=%s rootOrg=%s tenantOrg=%s client=%s\n\n' \
  "$ZITADEL_PROJECT_ID" "$ZITADEL_ROOT_ORG_ID" "$ZITADEL_ORG_ID" "$ZITADEL_CLIENT_ID"

for f in $BACKEND_FILES; do
  set_key "$VALUES_DIR/$f" ZITADEL_PROJECT_ID  "$ZITADEL_PROJECT_ID"
  set_key "$VALUES_DIR/$f" ZITADEL_ROOT_ORG_ID "$ZITADEL_ROOT_ORG_ID"
done
for f in $PROJECT_ONLY_FILES; do
  set_key "$VALUES_DIR/$f" ZITADEL_PROJECT_ID  "$ZITADEL_PROJECT_ID"
done
for f in $FRONTEND_FILES; do
  set_key "$VALUES_DIR/$f" ZITADEL_PROJECT_ID  "$ZITADEL_PROJECT_ID"
  set_key "$VALUES_DIR/$f" ZITADEL_ORG_ID      "$ZITADEL_ORG_ID"
  set_key "$VALUES_DIR/$f" ZITADEL_CLIENT_ID   "$ZITADEL_CLIENT_ID"
done

echo
if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$drift" -gt 0 ]; then
    echo "$drift value(s) differ from $ENV_FILE — run without --check to fix"; exit 1
  fi
  echo "all values files match $ENV_FILE"; exit 0
fi
echo "$changed value(s) updated"
cat <<'NOTE'

Not handled here — refresh these by hand after a Zitadel rebuild:
  - ASM hello-openshift/sbx/chat-secrets            -> JWT_PUBLIC_KEY (Zitadel JWKS)
  - ASM hello-openshift/sbx/scope-management-secrets -> ZITADEL_PAT (IAM_OWNER)
Then commit and let ArgoCD sync. Backends cache config at boot, so a
`oc -n unique rollout restart deploy/<name>` may be needed for env changes.
NOTE
