#!/usr/bin/env bash
#
# Create Harbor's registry endpoints and proxy-cache projects.
#
# The Helm chart cannot express these -- projects and remote registries are
# Harbor API objects, not Kubernetes ones -- so this is the Harbor equivalent of
# the reference deployment's setup-zitadel.sh: idempotent, re-runnable, run once per rebuild.
#
# What it builds, mirroring the ECR pull-through cache it replaces:
#
#   project    endpoint                  replaces
#   uniquecr   uniquecr.azurecr.io       the `uniquecr` ECR PTC prefix, 1:1 --
#                                        harbor/uniquecr/<repo> resolves to
#                                        uniquecr.azurecr.io/<repo>, so existing
#                                        `repository:` values need no change
#   dockerhub  docker.io                 direct internet pulls
#   quay       quay.io                   direct internet pulls -- registered as
#                                        the GENERIC docker-registry type, not
#                                        "quay": Harbor 2.15 accepts type quay
#                                        for replication but rejects it for a
#                                        proxy cache ("unsupported registry
#                                        type quay")
#   ghcr       ghcr.io                   direct internet pulls
#
# Projects are PUBLIC on purpose. The cluster is private, so Harbor is only
# reachable inside the VPC, and anonymous pull removes the need for robot
# accounts and a pull secret in every namespace. For a non-sandbox environment,
# make them private and issue a robot account instead.
#
# Reached via `oc port-forward` rather than the Route: the Route host resolves to
# the cluster-internal ingress NLB and is not routable from a workstation.
#
# Usage: setup-harbor-projects.sh [--check]
#   --check  report what is missing and exit 1 if anything is; create nothing
set -uo pipefail
cd "$(dirname "$0")/.."
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${AWS_PROFILE:=hello-openshift-sbx}"; export AWS_PROFILE

ADMIN_PW=$(aws secretsmanager get-secret-value --secret-id hello-openshift/sbx/harbor \
  --query SecretString --output text 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["admin_password"])' 2>/dev/null)
[ -z "$ADMIN_PW" ] && { echo "!! cannot read admin_password from ASM hello-openshift/sbx/harbor"; exit 1; }
ACR_USER=$(aws secretsmanager get-secret-value --secret-id hello-openshift/sbx/acr-pull \
  --query SecretString --output text 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' 2>/dev/null)
ACR_PASS=$(aws secretsmanager get-secret-value --secret-id hello-openshift/sbx/acr-pull \
  --query SecretString --output text 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' 2>/dev/null)
[ -z "$ACR_USER" ] || [ -z "$ACR_PASS" ] && {
  echo "!! cannot read a complete ACR credential (username+password) from ASM hello-openshift/sbx/acr-pull"
  exit 1
}

oc -n harbor get deploy harbor-core >/dev/null 2>&1 || { echo "!! harbor-core not deployed yet"; exit 1; }
oc -n harbor rollout status deploy/harbor-core --timeout=300s >/dev/null 2>&1 || echo "  (harbor-core not fully rolled out; continuing)"

oc -n harbor port-forward svc/harbor 18080:80 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for i in $(seq 1 30); do nc -z localhost 18080 2>/dev/null && break; sleep 2; done
nc -z localhost 18080 2>/dev/null || { echo "!! port-forward to harbor never came up"; exit 1; }
API=http://localhost:18080/api/v2.0
AUTH=(-u "admin:$ADMIN_PW")

api() { curl -sS --max-time 30 "${AUTH[@]}" -H 'Content-Type: application/json' "$@"; }

echo "  harbor version: $(api "$API/systeminfo" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("harbor_version","?"))' 2>/dev/null)"

# name|type|url|needs-credential
ENDPOINTS='uniquecr|azure-acr|https://uniquecr.azurecr.io|yes
dockerhub|docker-hub|https://hub.docker.com|no
quay|docker-registry|https://quay.io|no
ghcr|github-ghcr|https://ghcr.io|no'

FAILED=0
PENDING=0

# Fed by here-string, NOT `echo | while`: a piped loop runs in a subshell, so
# FAILED set inside it would be discarded and a failure could not change the
# script's exit status.
while IFS='|' read -r NAME TYPE URL NEEDCRED; do
  [ -n "$NAME" ] || continue
  EXISTING=$(api "$API/registries?q=name%3D$NAME" 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(d[0]["id"] if isinstance(d,list) and d else "")' 2>/dev/null)

  if [ -n "$EXISTING" ]; then
    echo "  registry  $NAME already exists (id=$EXISTING)"
    REG_ID=$EXISTING
  elif [ "$CHECK" -eq 1 ]; then
    echo "  PENDING   registry $NAME absent"
    PENDING=1
    continue
  else
    if [ "$NEEDCRED" = "yes" ]; then
      BODY=$(python3 -c '
import json,sys
n,t,u,usr,pw=sys.argv[1:6]
print(json.dumps({"name":n,"type":t,"url":u,"insecure":False,
  "credential":{"type":"basic","access_key":usr,"access_secret":pw}}))' "$NAME" "$TYPE" "$URL" "$ACR_USER" "$ACR_PASS")
    else
      BODY=$(python3 -c '
import json,sys
n,t,u=sys.argv[1:4]
print(json.dumps({"name":n,"type":t,"url":u,"insecure":False}))' "$NAME" "$TYPE" "$URL")
    fi
    CODE=$(api -o /dev/null -w '%{http_code}' -X POST "$API/registries" -d "$BODY")
    case "$CODE" in
      20*) echo "  registry  $NAME created (http $CODE)" ;;
      *)   echo "  !! registry $NAME NOT created (http $CODE)" >&2
           FAILED=1
           continue ;;
    esac
    REG_ID=$(api "$API/registries?q=name%3D$NAME" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null)
  fi

  # Never fall back to registry_id 0. Harbor accepts it and creates an ordinary
  # project bound to no upstream, so every pull through it 404s -- and because
  # the HEAD probe below then reports "already exists", no re-run can ever
  # repair it. Refusing to create the project keeps the tree fixable.
  if [ -z "${REG_ID:-}" ]; then
    echo "  !! no registry id for $NAME; refusing to create a project with no upstream" >&2
    FAILED=1
    continue
  fi

  # proxy-cache project bound to that endpoint.
  #
  # Existence MUST be probed with HEAD, not GET. `GET /projects?project_name=X`
  # returns 200 with an empty list when nothing matches, so a 200 says only "the
  # query worked" -- treating it as "exists" silently skipped every creation and
  # the script cheerfully reported "already exists" against an empty Harbor.
  # `HEAD /projects?project_name=X` is the real existence check: 200 or 404.
  # --head, not -X HEAD: with -X curl still waits for a response body and the
  # call sits until the 30s timeout before returning a usable code.
  PCODE=$(api -o /dev/null -w '%{http_code}' --head "$API/projects?project_name=$NAME")
  if [ "$PCODE" = "200" ]; then
    echo "  project   $NAME already exists"
  elif [ "$CHECK" -eq 1 ]; then
    echo "  PENDING   project $NAME absent"
    PENDING=1
  else
    PBODY=$(python3 -c '
import json,sys
n,rid=sys.argv[1],int(sys.argv[2])
print(json.dumps({"project_name":n,"public":True,"registry_id":rid,
  "metadata":{"public":"true"}}))' "$NAME" "$REG_ID")
    CODE=$(api -o /dev/null -w '%{http_code}' -X POST "$API/projects" -d "$PBODY")
    case "$CODE" in
      20*) echo "  project   $NAME created as proxy cache (http $CODE)" ;;
      *)   echo "  !! project $NAME NOT created (http $CODE)" >&2; FAILED=1 ;;
    esac
  fi
done <<< "$ENDPOINTS"

echo
echo "  pull path: <harbor-host>/uniquecr/<repo>:<tag>  ->  uniquecr.azurecr.io/<repo>:<tag>"
# Guard, not the script's exit status: as the last command, a bare
# `[ test ] && echo` made every successful non---check run exit 1.
if [ "$CHECK" -eq 1 ]; then
  echo "  (--check: nothing was created)"
  [ "$PENDING" -eq 0 ] || { echo "=> INCOMPLETE (run without --check)"; exit 1; }
fi
[ "$FAILED" -eq 0 ] || { echo "=> FAILED"; exit 1; }
echo "=> done"
