#!/usr/bin/env bash
#
# Platform smoke test — one pass over every layer, PASS/FAIL per check.
#
# Written to answer "is this rebuild actually working?" without trawling through
# fifteen ArgoCD applications by hand. Each check is deliberately shallow: it
# proves a layer is serving, not that it is correct.
#
# Requires an authenticated `oc` session. The cluster is private, so that means
# SSM port-forwards to the private API endpoint — the reliable shape
# is a self-contained wrapper that opens the tunnels, authenticates, runs this,
# and tears down.
#
# Usage:
#   scripts/smoke-test.sh            # all checks
#   scripts/smoke-test.sh --quiet    # summary line only
#
# Exit code is the number of failures (0 = everything passed), so it can gate a
# script or a CI step.
set -uo pipefail
cd "$(dirname "$0")/.."
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)   QUIET=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${AWS_PROFILE:=hello-openshift-sbx}"; export AWS_PROFILE

P=0; F=0; SK=0
say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }
ok()   { [ "$QUIET" -eq 1 ] || printf "  \033[32mPASS\033[0m  %-38s %s\n" "$1" "${2:-}"; P=$((P+1)); }
bad()  {                       printf "  \033[31mFAIL\033[0m  %-38s %s\n" "$1" "${2:-}"; F=$((F+1)); }
skip() { [ "$QUIET" -eq 1 ] || printf "  ----  %-38s %s\n" "$1" "${2:-}"; SK=$((SK+1)); }

# the registry hostname is the one value the pull check needs; it lives in the
# same env file that set-cluster-domain.sh owns
HARBOR_REGISTRY_HOST=harbor.openshift.example.com
[ -f gitops/environments/sbx/cluster-domain.env ] && \
  . gitops/environments/sbx/cluster-domain.env 2>/dev/null || true

say "== 1. cluster =="
N=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NR=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
[ "$N" != "0" ] && [ "$N" = "$NR" ] && ok "nodes Ready" "$NR/$N" || bad "nodes Ready" "$NR/$N"
CO_BAD=$(oc get co --no-headers 2>/dev/null | awk '$3!="True"' | wc -l | tr -d ' ')
[ "$CO_BAD" = "0" ] && ok "cluster operators Available" "all" || bad "cluster operators Available" "$CO_BAD unavailable"
# `network` is degraded permanently: multus crash-loops on a --no-cni cluster
# because nothing populates /run/multus/cni/net.d. Cilium carries the datapath,
# so this is accepted, not broken.
CO_DEG=$(oc get co --no-headers 2>/dev/null | awk '$5=="True" {print $1}' | paste -sd, -)
case "${CO_DEG:-}" in
  "")        ok "no degraded operators" "" ;;
  "network") ok "only known degradation" "network (multus, expected on --no-cni)" ;;
  *)         bad "unexpected degraded operators" "$CO_DEG" ;;
esac

say "== 2. CNI =="
CA=$(oc -n cilium get pods -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "1/1")
[ "$CA" = "$N" ] && ok "cilium agents" "$CA/$N" || bad "cilium agents" "$CA/$N"

say "== 3. gitops =="
APPS=$(oc -n openshift-gitops get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')
AH=$(oc -n openshift-gitops get applications --no-headers 2>/dev/null | awk '$3=="Healthy"' | wc -l | tr -d ' ')
AD=$(oc -n openshift-gitops get applications --no-headers 2>/dev/null | awk '$3!="Healthy" {print $1}' | paste -sd, -)
[ "$APPS" != "0" ] && [ "$APPS" = "$AH" ] && ok "applications healthy" "$AH/$APPS" \
  || bad "applications healthy" "$AH/$APPS  not healthy: ${AD:-none}"

say "== 4. registry (Harbor) =="
HT=$(oc -n harbor get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
HP=$(oc -n harbor get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") c++} END {print c+0}')
[ "$HT" != "0" ] && [ "$HP" = "$HT" ] && ok "harbor pods ready" "$HP/$HT" || bad "harbor pods ready" "$HP/$HT"
OBC=$(oc -n harbor get obc harbor-registry -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$OBC" = "Bound" ] && ok "blob store (NooBaa OBC)" "Bound" || bad "blob store (NooBaa OBC)" "${OBC:-absent}"
ELB=$(oc -n harbor get svc harbor-registry-elb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
[ -n "$ELB" ] && ok "registry ELB provisioned" "${ELB%%-*}…" || bad "registry ELB provisioned" "none"
# The only check that exercises the path CRI-O really uses: node -> private-zone
# DNS -> internal ELB -> Harbor -> ACR. The Route cannot serve pulls (NLB
# loopback), so a green Route proves nothing here.
oc -n harbor delete pod smoke-pull --ignore-not-found >/dev/null 2>&1
cat <<YAML | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: {name: smoke-pull, namespace: harbor}
spec:
  restartPolicy: Never
  containers:
    - name: p
      image: "${HARBOR_REGISTRY_HOST}/uniquecr/web-app-chat:2026.34.4"
      command: ["sh","-c","sleep 2"]
YAML
PULL="timeout"
for _ in $(seq 1 30); do
  ph=$(oc -n harbor get pod smoke-pull -o jsonpath='{.status.phase}' 2>/dev/null)
  rs=$(oc -n harbor get pod smoke-pull -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  case "$ph" in Running|Succeeded) PULL="ok"; break;; esac
  case "$rs" in ErrImagePull|ImagePullBackOff) PULL="pull failed"; break;; esac
  sleep 5
done
[ "$PULL" = "ok" ] && ok "image pull through Harbor" "uniquecr/web-app-chat:2026.34.4" \
  || bad "image pull through Harbor" "$PULL"
oc -n harbor delete pod smoke-pull --ignore-not-found >/dev/null 2>&1

say "== 5. data services =="
PG=$(oc -n hello-openshift-data get cluster.postgresql.cnpg.io hello-openshift-postgres -o jsonpath='{.status.readyInstances}' 2>/dev/null)
{ [ -n "$PG" ] && [ "$PG" -ge 1 ]; } 2>/dev/null && ok "postgres (CNPG)" "$PG ready" || bad "postgres (CNPG)" "${PG:-0} ready"
for entry in "hello-openshift-data:redis" "eventing:rabbitmq" "finance-gpt:qdrant"; do
  ns=${entry%%:*}; app=${entry##*:}
  c=$(oc -n "$ns" get pods --no-headers 2>/dev/null | grep -i "$app" | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") x++} END {print x+0}')
  { [ "${c:-0}" -ge 1 ]; } 2>/dev/null && ok "$app" "$c pod(s) ready" || bad "$app" "none ready in $ns"
done
NB=$(oc -n openshift-storage get noobaa noobaa -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$NB" = "Ready" ] && ok "object storage (NooBaa)" "Ready" || bad "object storage (NooBaa)" "${NB:-absent}"
# Regression guard: NooBaa defaults its s3/sts Services to type LoadBalancer and
# AWS answers with INTERNET-FACING Classic ELBs, publishing sandbox object
# storage to the world. disableLoadBalancerService: true in the StorageCluster
# settles it; this check makes sure it stays settled.
# Checked in-cluster, on the Services themselves. The previous version counted
# internet-facing Classic ELBs account-wide in a hardcoded region, so any
# unrelated load balancer anywhere in the account failed the whole run -- and it
# could not tell a NooBaa ELB from someone else's.
LBSVC=$(oc -n openshift-storage get svc --no-headers 2>/dev/null | awk '$2=="LoadBalancer" {print $1}' | paste -sd, -)
[ -z "$LBSVC" ] && ok "no LoadBalancer Services in openshift-storage" "0" \
  || bad "LoadBalancer Services in openshift-storage" "$LBSVC — NooBaa exposure regressed?"

say "== 6. identity =="
Z=$(oc -n zitadel get pods --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") c++} END {print c+0}')
{ [ "${Z:-0}" -ge 1 ]; } 2>/dev/null && ok "zitadel pods" "$Z ready" || bad "zitadel pods" "none ready"

say "== 7. inference =="
LL=$(oc -n system get pods --no-headers 2>/dev/null | grep "^litellm-" | grep -v migrations \
  | awk '{split($2,a,"/"); if(a[1]==a[2] && $3=="Running") c++} END {print c+0}')
{ [ "${LL:-0}" -ge 1 ]; } 2>/dev/null && ok "litellm proxy" "$LL ready" || bad "litellm proxy" "none ready"

say "== 8. chat slice (wave 6) =="
W6=$(oc -n openshift-gitops get applications --no-headers 2>/dev/null | grep -cE 'web-app-|backend-service-|assistants-core')
if [ "${W6:-0}" = "0" ]; then
  skip "wave 6 applications" "not created yet — an earlier wave is still unhealthy"
else
  W6H=$(oc -n openshift-gitops get applications --no-headers 2>/dev/null \
    | grep -E 'web-app-|backend-service-|assistants-core' | awk '$3=="Healthy"' | wc -l | tr -d ' ')
  [ "$W6" = "$W6H" ] && ok "wave 6 applications" "$W6H/$W6 healthy" || bad "wave 6 applications" "$W6H/$W6 healthy"
fi
# Count only pods that are SUPPOSED to be running. Completed pods are finished
# Jobs -- the migration hooks each backend runs once -- and counting them as
# unready made a fully working slice report a failure.
U=$(oc -n unique get pods --no-headers 2>/dev/null | awk '$3!="Completed" && $3!="Succeeded"' | wc -l | tr -d ' ')
DONE=$(oc -n unique get pods --no-headers 2>/dev/null | awk '$3=="Completed" || $3=="Succeeded"' | wc -l | tr -d ' ')
if [ "${U:-0}" = "0" ]; then
  skip "chat workloads" "no long-running pods${DONE:+ ($DONE completed job(s))}"
else
  UR=$(oc -n unique get pods --no-headers 2>/dev/null \
    | awk '$3=="Running" {split($2,a,"/"); if(a[1]==a[2]) c++} END {print c+0}')
  [ "$U" = "$UR" ] && ok "chat workloads" "$UR/$U ready${DONE:+, $DONE job(s) completed}" \
    || bad "chat workloads" "$UR/$U ready"
fi

printf '\n  PASS %d   FAIL %d   SKIP %d\n' "$P" "$F" "$SK"
exit "$F"
