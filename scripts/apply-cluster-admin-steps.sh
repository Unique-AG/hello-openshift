#!/usr/bin/env bash
#
# The cluster-level settings ArgoCD cannot manage, made idempotent.
#
# These exist because ArgoCD either cannot express them or
# is denied by the ROSA admission webhooks, and every one of them has bitten this
# project at least once:
#   - without the controller RBAC, apps sit OutOfSync with a "forbidden ... cannot
#     patch resource" that reads like an AppProject problem but never is
#   - without InterNamespaceAllowed, path-based Routes on the shared host are
#     rejected as HostAlreadyClaimed
#   - the root Application is the one ArgoCD object nobody else applies
#
# Assumes you are already logged in (the private cluster needs an SSM tunnel and a token
# flow). Safe to re-run; --check reports without changing anything.
#
# Usage:
#   scripts/apply-cluster-admin-steps.sh
#   scripts/apply-cluster-admin-steps.sh --check
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail=0
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok      %s\n' "$1"; }
todo() { printf '   PENDING %s\n' "$1"; fail=$((fail+1)); }
did()  { printf '   applied %s\n' "$1"; }

oc whoami >/dev/null 2>&1 || { echo "!! not logged in to a cluster (the cluster is private: open an SSM tunnel first)"; exit 1; }
printf 'cluster: %s\nuser:    %s\n' "$(oc whoami --show-server 2>/dev/null)" "$(oc whoami 2>/dev/null)"

# ── 1. ArgoCD controller RBAC for third-party CRDs ────────────────────────────
step "ArgoCD controller RBAC (external-secrets, kata, runtimeclasses, agent-sandbox, cilium)"
if oc get clusterrole openshift-gitops-argocd-extra >/dev/null 2>&1 &&
   oc get clusterrole openshift-gitops-argocd-extra -o json 2>/dev/null | grep -q 'extensions.agents.x-k8s.io' &&
   oc get clusterrole openshift-gitops-argocd-extra -o json 2>/dev/null | grep -q 'cilium.io'; then
  ok "clusterrole present and includes the agent-sandbox + cilium groups"
else
  if [ "$CHECK_ONLY" -eq 1 ]; then
    todo "clusterrole missing or stale -> oc apply -f gitops/bootstrap/argocd/controller-rbac.yaml"
  else
    oc apply -f "$REPO_ROOT/gitops/bootstrap/argocd/controller-rbac.yaml" >/dev/null 2>&1 \
      && did "controller-rbac.yaml" || todo "controller-rbac.yaml FAILED to apply"
  fi
fi

# ── 2. Route admission across namespaces ──────────────────────────────────────
step "IngressController routeAdmission = InterNamespaceAllowed"
CUR=$(oc -n openshift-ingress-operator get ingresscontroller default \
       -o jsonpath='{.spec.routeAdmission.namespaceOwnership}' 2>/dev/null)
if [ "$CUR" = "InterNamespaceAllowed" ]; then
  ok "already InterNamespaceAllowed"
elif [ "$CHECK_ONLY" -eq 1 ]; then
  todo "currently '${CUR:-Strict}' — path-based Routes across namespaces will be rejected"
else
  oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge \
    -p '{"spec":{"routeAdmission":{"namespaceOwnership":"InterNamespaceAllowed"}}}' >/dev/null 2>&1 \
    && did "patched to InterNamespaceAllowed" || todo "patch FAILED"
fi

# ── 3. Kata node labels (must precede the KataConfig) ─────────────────────────
step "worker labels node-role.kubernetes.io/kata-oc="
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null)
if [ -z "$WORKERS" ]; then
  todo "no worker nodes found"
else
  for n in $WORKERS; do
    if oc get "$n" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'kata-oc'; then
      ok "$n already labelled"
    elif [ "$CHECK_ONLY" -eq 1 ]; then
      todo "$n unlabelled — the operator will sit in WaitingForMcoToStart forever"
    else
      oc label "$n" node-role.kubernetes.io/kata-oc= --overwrite >/dev/null 2>&1 \
        && did "$n labelled" || todo "$n label FAILED"
    fi
  done
fi

# ── 4. The hand-applied ArgoCD control plane ──────────────────────────────────
# The AppProject, the uniquecr repo credential and the `sbx` ApplicationSet.
# These are the only ArgoCD objects nobody else applies: the AppProject has to
# exist before any Application in it can sync, so it cannot be managed by an
# Application inside that project. Everything the ApplicationSet generates IS
# self-healing.
step "ArgoCD control plane (AppProject + repo cred + ApplicationSet)"
if oc -n openshift-gitops get applicationset sbx >/dev/null 2>&1; then
  ok "applicationset/sbx exists"
  if [ "$CHECK_ONLY" -eq 0 ]; then
    oc apply -k "$REPO_ROOT/gitops/bootstrap/envs/sbx" >/dev/null 2>&1 \
      && did "re-applied (picks up template/ignoreDifferences edits)" || todo "re-apply FAILED"
  fi
elif [ "$CHECK_ONLY" -eq 1 ]; then
  todo "applicationset/sbx absent -> oc apply -k gitops/bootstrap/envs/sbx"
else
  oc apply -k "$REPO_ROOT/gitops/bootstrap/envs/sbx" >/dev/null 2>&1 \
    && did "applicationset/sbx created" || todo "applicationset apply FAILED"
fi

# ── 5. Not scriptable: reported, never guessed ────────────────────────────────
step "manual, NOT automated here"
if oc get machineconfig 50-enable-sandboxed-containers-extension >/dev/null 2>&1; then
  ok "MachineConfig 50-enable-sandboxed-containers-extension present"
else
  todo "MachineConfig 50-enable-sandboxed-containers-extension absent. It must be
           pre-created by a cluster-admin because the ROSA regular-user-validation
           webhook denies the OPERATOR's SA writing MachineConfig objects, while the
           cluster-admins group is exempt. The spec must match what the operator
           logs EXACTLY (it DeepEquals), so copy it from the operator log rather
           than inventing it."
fi
if oc get machineconfigpool kata-oc >/dev/null 2>&1; then
  ok "MachineConfigPool kata-oc present"
else
  todo "MachineConfigPool kata-oc absent (Get-first, never update)"
fi

printf '\n'
if [ "$fail" -gt 0 ]; then
  echo "$fail item(s) still need attention"
  [ "$CHECK_ONLY" -eq 1 ] && echo "re-run without --check to apply the automatable ones"
  exit 1
fi
echo "all cluster-admin steps satisfied"
