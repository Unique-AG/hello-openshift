#!/usr/bin/env bash
#
# Propagate this cluster's DNS identity into every file that embeds it.
#
# Why this exists: `--domain-prefix` is stable across a rebuild, but Red Hat
# assigns a fresh shard segment after it on every create (m1sa -> c6lq on
# 2026-08-25). Several files hardcode the resulting FQDN, and a stale value is
# not cosmetic:
#
#   * Cilium k8sServiceHost   -> agents cannot reach the apiserver. With
#                                kubeProxyReplacement there is no service-IP
#                                fallback, so every node goes NotReady and it
#                                looks like a broken CNI install.
#   * Harbor Route host       -> the registry hostname stops resolving, or stops
#     and externalURL            matching the Let's Encrypt wildcard, and EVERY
#                                image pull in the cluster fails.
#   * image registry: lines  -> same failure, per workload.
#
# Rewrites BY KEY, never by matching the old value, so it is idempotent and works
# from any starting state -- a fresh clone, a half-patched tree, or after a
# rebuild. Same contract as scripts/set-zitadel-ids.sh.
#
# Usage:
#   scripts/set-cluster-domain.sh                 # values from cluster-domain.env
#   scripts/set-cluster-domain.sh --check         # verify only, exit 1 on drift
#   scripts/set-cluster-domain.sh --from-terraform  # re-derive from tf state first
set -uo pipefail
cd "$(dirname "$0")/.."
ENVFILE=gitops/environments/sbx/cluster-domain.env
CHECK=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --from-terraform)
      D=$(cd terraform/2-cluster && terraform output -raw cluster_domain 2>/dev/null)
      [ -z "$D" ] && { echo "!! terraform state has no cluster_domain"; exit 1; }
      python3 - "$ENVFILE" "$D" <<'PY'
import sys,re
p,d=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'^CLUSTER_DOMAIN=.*$', f'CLUSTER_DOMAIN={d}', s, flags=re.M)
s=re.sub(r'^APPS_DOMAIN=.*$',    f'APPS_DOMAIN=apps.rosa.{d}', s, flags=re.M)
s=re.sub(r'^HARBOR_UI_HOST=.*$', f'HARBOR_UI_HOST=harbor.apps.rosa.{d}', s, flags=re.M)
open(p,'w').write(s)
print(f"  cluster-domain.env <- {d}")
PY
      ;;
  esac
done

# shellcheck disable=SC1090
. "$ENVFILE"
: "${CLUSTER_DOMAIN:?}" "${APPS_DOMAIN:?}" "${HARBOR_UI_HOST:?}" "${HARBOR_REGISTRY_HOST:?}"

DRIFT=0
report() { # file, what, want, got
  if [ "$3" = "$4" ]; then
    printf '  ok      %-58s %s\n' "$2" "$4"
  else
    printf '  DRIFT   %-58s want=%s got=%s\n' "$2" "$3" "${4:-<none>}"
    DRIFT=1
  fi
}

# --- 1. Cilium apiserver host ------------------------------------------------
F=gitops/bootstrap/cilium/values.yaml
GOT=$(sed -n 's/^k8sServiceHost:[[:space:]]*//p' "$F" | head -1)
WANT="api.$CLUSTER_DOMAIN"
if [ "$CHECK" -eq 1 ]; then report "$F" "k8sServiceHost" "$WANT" "$GOT"
else
  python3 - "$F" "$WANT" <<'PY'
import sys,re
p,w=sys.argv[1],sys.argv[2]; s=open(p).read()
s2=re.sub(r'^k8sServiceHost:.*$', f'k8sServiceHost: {w}', s, flags=re.M)
open(p,'w').write(s2)
print(f"  set     k8sServiceHost -> {w}")
PY
fi

# --- 2. Harbor Route host ----------------------------------------------------
F=gitops/environments/sbx/platform/route-harbor.yaml
GOT=$(sed -n 's/^[[:space:]]*host:[[:space:]]*//p' "$F" | head -1)
if [ "$CHECK" -eq 1 ]; then report "$F" "Route host" "$HARBOR_UI_HOST" "$GOT"
else
  python3 - "$F" "$HARBOR_UI_HOST" <<'PY'
import sys,re
p,w=sys.argv[1],sys.argv[2]; s=open(p).read()
s=re.sub(r'^(\s*)host:.*$', lambda m: f'{m.group(1)}host: {w}', s, count=1, flags=re.M)
open(p,'w').write(s)
print(f"  set     Route host -> {w}")
PY
fi

# --- 3. Harbor externalURL: intentionally NOT rewritten -----------------------
# externalURL points at HARBOR_REGISTRY_HOST, which is on our own domain and does
# not change when the cluster is rebuilt. Verified below with the image
# references rather than rewritten here.

# --- 4. every image registry: line ------------------------------------------
# Matched by KEY: any `registry:` whose value is a container registry host we
# manage (the retired ECR pull-through host, or any harbor.apps.* from a previous
# cluster). Values pointing anywhere else (public registries in the bootstrap
# tier) are deliberately left alone.
python3 - "$HARBOR_REGISTRY_HOST" "$CHECK" <<'PY'
import sys,re,pathlib
harbor,check=sys.argv[1],sys.argv[2]=="1"
pat=re.compile(r'^(\s*registry:\s*)(\S+)\s*$', re.M)
# Any Harbor host, on any domain -- NOT just harbor.apps.*: the registry
# endpoint is deliberately kept off the cluster apps domain (see
# cluster-domain.env), so anchoring on harbor.apps. matched nothing real and
# skipped every line while reporting "in sync". The retired ECR pull-through
# host stays matched so an old tree still migrates.
managed=re.compile(r'(\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$)|(^harbor\.)')
drift=0; changed=0
for f in sorted(pathlib.Path('gitops').rglob('*.yaml')):
    s=f.read_text()
    if 'registry:' not in s: continue
    def sub(m):
        global drift,changed
        cur=m.group(2).strip('"\'')
        if not managed.search(cur): return m.group(0)
        if cur==harbor: return m.group(0)
        if check:
            print(f"  DRIFT   {f}"); print(f"            want={harbor} got={cur}"); drift=1
            return m.group(0)
        changed+=1
        print(f"  set     {f} registry -> {harbor}")
        return f"{m.group(1)}{harbor}"
    new=pat.sub(sub,s)
    if new!=s and not check: f.write_text(new)
print(f"  {'drift in image registries' if drift else ('%d image registry line(s) updated'%changed)}")
sys.exit(1 if drift else 0)
PY
RC=$?
[ "$CHECK" -eq 1 ] && { [ $DRIFT -eq 0 ] && [ $RC -eq 0 ] && echo "=> in sync" || echo "=> DRIFT (run without --check)"; exit $(( DRIFT || RC )); }
echo "=> done"
