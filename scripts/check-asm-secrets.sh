#!/usr/bin/env bash
#
# Inventory of every AWS Secrets Manager secret this deployment consumes, and a
# check of whether each one exists with the keys the services actually read.
#
# Why: the secrets are split between Terraform-managed and hand-created, the
# hand-created ones are undocumented outside commit messages, and a missing KEY
# (rather than a missing secret) fails in ways that look unrelated — e.g. a
# missing INGESTION_ENCRYPTION_KEY makes the chart's migration hook Job fail so
# the whole app never syncs, and a missing LITELLM_API_KEY crashlooped node-chat
# once every five minutes for 37 days.
#
# Prints secret and key NAMES only — never values.
#
# Usage:
#   scripts/check-asm-secrets.sh                # check everything
#   scripts/check-asm-secrets.sh --missing-only
#
set -uo pipefail

REGION="${AWS_REGION:-eu-central-2}"
PROFILE="${AWS_PROFILE:-hello-openshift-sbx}"
MISSING_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --missing-only) MISSING_ONLY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# id | owner | required keys (space separated; "-" = any/unchecked) | consumed by
SPECS='
hello-openshift/sbx/redis|terraform 1-foundation|password|data-services redis-auth ExternalSecret (Opstree Redis AUTH)
hello-openshift/sbx/minio|terraform 1-foundation|-|legacy; ODF NooBaa replaced MinIO — verify still referenced before recreating
hello-openshift/sbx/chat-db|manual|password|every backend DATABASE_URL (structured mode, CNPG app_user)
hello-openshift/sbx/chat-secrets|manual|CHAT_LXM_ENCRYPTION_KEY JWT_PUBLIC_KEY AZURE_OPENAI_API_ENDPOINTS_JSON LITELLM_API_KEY|node-chat extraEnvSecrets
hello-openshift/sbx/assistants-core-secrets|manual|OPENAI_API_KEY OPENAI_BASE_URL|assistants-core extraEnvSecrets
hello-openshift/sbx/scope-management-secrets|manual|ZITADEL_PAT|scope-management (IAM_OWNER PAT for user sync)
hello-openshift/sbx/ingestion-secrets|manual|AZURE_OPENAI_API_KEY INGESTION_ENCRYPTION_KEY|node-ingestion extraEnvSecrets
hello-openshift/sbx/litellm|manual|DATABASE_URL PROXY_MASTER_KEY ANTHROPIC_API_KEY|litellm proxy (master key + prisma DSN)
hello-openshift/sbx/harbor|manual|admin_password secret_key|Harbor admin password + 16-char secretKey (encrypts stored registry creds)
hello-openshift/sbx/rabbitmq|manual|username password erlangCookie consumerUsername consumerPassword|RabbitMQ cluster; username MUST be "admin"
hello-openshift/sbx/acr-pull|manual|username password|ArgoCD OCI repo cred for uniquecr charts
hello-openshift/sbx/peer-pods|manual|-|kata peer-pods EC2 launches (unused while kata runs runc)
manual-zitadel-scope-mgmt-pat|manual, pre-create before setup-zitadel.sh|-|setup-zitadel.sh writes the scope-mgmt PAT here; its final put-secret-value FAILS if absent
'

ok=0; missing=0; partial=0

printf '%-46s %-34s %s\n' SECRET STATUS DETAIL
printf '%-46s %-34s %s\n' "----------------------------------------------" "----------------------------------" "------"

while IFS='|' read -r sid owner keys consumer; do
  [ -z "${sid:-}" ] && continue
  json=$(aws secretsmanager get-secret-value --secret-id "$sid" \
          --region "$REGION" --profile "$PROFILE" \
          --query SecretString --output text 2>/dev/null)
  if [ -z "$json" ]; then
    printf '%-46s %-34s %s\n' "$sid" "MISSING" "owner=$owner"
    printf '%-46s %-34s %s\n' "" "" "needed by: $consumer"
    missing=$((missing+1)); continue
  fi
  present=$(printf '%s' "$json" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('__NOTJSON__'); raise SystemExit
print(' '.join(sorted(d.keys())))
" 2>/dev/null)
  if [ "$present" = "__NOTJSON__" ]; then
    [ "$MISSING_ONLY" -eq 1 ] || printf '%-46s %-34s %s\n' "$sid" "present (plain string)" "owner=$owner"
    ok=$((ok+1)); continue
  fi
  if [ "$keys" = "-" ]; then
    [ "$MISSING_ONLY" -eq 1 ] || printf '%-46s %-34s %s\n' "$sid" "present" "keys: ${present:-none}"
    ok=$((ok+1)); continue
  fi
  lack=""
  for k in $keys; do
    case " $present " in *" $k "*) ;; *) lack="$lack $k";; esac
  done
  if [ -n "$lack" ]; then
    printf '%-46s %-34s %s\n' "$sid" "MISSING KEYS" "lacks:$lack"
    printf '%-46s %-34s %s\n' "" "" "needed by: $consumer"
    partial=$((partial+1))
  else
    [ "$MISSING_ONLY" -eq 1 ] || printf '%-46s %-34s %s\n' "$sid" "ok" "all $(echo "$keys" | wc -w | tr -d ' ') keys present"
    ok=$((ok+1))
  fi
done <<< "$SPECS"

echo
echo "ok=$ok  missing-secret=$missing  missing-keys=$partial"
if [ "$missing" -gt 0 ] || [ "$partial" -gt 0 ]; then
  echo "=> create the missing secrets/keys before syncing the chat + conduct apps"
  exit 1
fi
echo "=> every required secret and key is in place"
