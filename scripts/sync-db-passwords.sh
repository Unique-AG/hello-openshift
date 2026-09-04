#!/usr/bin/env bash
#
# Re-point every stored database credential at the CURRENT CNPG password.
#
# Why this exists: `app_user` is CNPG's bootstrap owner, so the operator
# GENERATES its password at initdb and publishes it in the
# hello-openshift-postgres-app secret. The copies in AWS Secrets Manager do not
# follow, so after a cluster rebuild every consumer fails with
#
#   Error: P1000: Authentication failed against database server, the provided
#   database credentials for `app_user` are not valid.
#
# and the failure is well disguised. The five chat backends look like an image or
# chart problem, because their web pods run perfectly and only the `*-migration`
# Jobs Error. litellm reports "httpx.ConnectError: All connection attempts
# failed", which is litellm failing to reach its own local prisma engine after
# that engine exited on the auth error -- two layers below the real cause.
#
# Same family as scripts/configure-instance.sh: a rebuild invalidates credentials
# generated INSIDE the old cluster, and the stored copies must be re-synced.
#
# Consumers handled here:
#   hello-openshift/sbx/chat-db   username + password  (the five chat backends
#                                 build DATABASE_URL in structured mode from these)
#   hello-openshift/sbx/litellm   DATABASE_URL         (credentials inside a URL)
#
# Usage:
#   scripts/sync-db-passwords.sh            # sync, then force the ESO refresh
#   scripts/sync-db-passwords.sh --check    # report drift only, exit 1 if stale
set -uo pipefail
cd "$(dirname "$0")/.."
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${AWS_PROFILE:=hello-openshift-sbx}"
export AWS_PROFILE

USER=$(oc -n hello-openshift-data get secret hello-openshift-postgres-app -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
PASS=$(oc -n hello-openshift-data get secret hello-openshift-postgres-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
if [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "!! cannot read hello-openshift-data/hello-openshift-postgres-app - is CNPG up and oc logged in?"
  exit 1
fi
echo "  live CNPG owner: $USER (password ${#PASS} chars)"
DRIFT=0

sync_secret() {   # $1 = ASM id, $2 = mode (plain|url), $3 = label
  local id="$1" mode="$2" label="$3" cur tmp state
  cur=$(aws secretsmanager get-secret-value --secret-id "$id" --query SecretString --output text 2>/dev/null)
  if [ -z "$cur" ]; then
    echo "  !!      cannot read ASM $id"; DRIFT=1; return
  fi
  tmp=$(mktemp)
  state=$(SYNC_CUR="$cur" SYNC_USER="$USER" SYNC_PASS="$PASS" SYNC_OUT="$tmp" SYNC_MODE="$mode" python3 -c '
import json,os,re,urllib.parse
cur=os.environ["SYNC_CUR"]; user=os.environ["SYNC_USER"]; pw=os.environ["SYNC_PASS"]
out=os.environ["SYNC_OUT"]; mode=os.environ["SYNC_MODE"]
d=json.loads(cur)
if mode=="plain":
    same = d.get("username")==user and d.get("password")==pw
    d["username"],d["password"]=user,pw
else:
    old=d.get("DATABASE_URL","")
    m=re.match(r"^(?P<scheme>\w+://)(?P<creds>[^@]*)@(?P<rest>.+)$", old)
    if not m:
        print("UNPARSEABLE"); raise SystemExit(0)
    new=m.group("scheme")+urllib.parse.quote(user,safe="")+":"+urllib.parse.quote(pw,safe="")+"@"+m.group("rest")
    same = new==old
    d["DATABASE_URL"]=new
open(out,"w").write(json.dumps(d))
print("SAME" if same else "STALE")
')
  case "$state" in
    SAME)        echo "  ok      $label already current" ;;
    UNPARSEABLE) echo "  !!      $label is not a parseable URL"; DRIFT=1 ;;
    STALE)
      if [ "$CHECK" -eq 1 ]; then
        echo "  DRIFT   $label does not match CNPG"; DRIFT=1
      else
        aws secretsmanager put-secret-value --secret-id "$id" \
          --secret-string "file://$tmp" --query VersionId --output text >/dev/null 2>&1 \
          && echo "  set     $label" || { echo "  !!      failed to write $id"; DRIFT=1; }
      fi ;;
    *)           echo "  !!      $label: unexpected state '${state:-empty}'"; DRIFT=1 ;;
  esac
  rm -f "$tmp"
}

sync_secret hello-openshift/sbx/chat-db plain "chat-db username/password"
sync_secret hello-openshift/sbx/litellm url   "litellm DATABASE_URL"
unset PASS

if [ "$CHECK" -eq 1 ]; then
  [ "$DRIFT" -eq 0 ] && echo "  => in sync" || echo "  => DRIFT (run without --check)"
  exit "$DRIFT"
fi

# these ExternalSecrets refresh every 24h, so nudge them rather than wait
echo "  forcing ESO to refetch..."
oc -n unique annotate externalsecret chat-db force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 && echo "    unique/chat-db"
oc -n system annotate externalsecret litellm force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 && echo "    system/litellm"

echo
echo "  Consumers do NOT pick this up on their own:"
echo "    - failed migration Jobs must be deleted so ArgoCD recreates them"
echo "    - running Deployments need a restart to reread the secret"
exit "$DRIFT"
