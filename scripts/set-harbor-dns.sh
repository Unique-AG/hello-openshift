#!/usr/bin/env bash
#
# Point harbor.openshift.example.com at the internal ELB that Kubernetes
# created for the harbor-registry-elb Service.
#
# Why a script and not Terraform: the load balancer is created by the Kubernetes
# AWS cloud provider in response to a Service of type LoadBalancer, so Terraform
# does not own it and its generated name is not knowable at plan time. Terraform
# owns the private hosted zone (terraform/2-cluster/harbor-dns.tf); this fills in
# the one record that has to follow the cluster.
#
# Idempotent: an UPSERT, safe to re-run. Run it after a rebuild, and any time the
# Service is recreated (a new Service means a new ELB and a new DNS name).
#
# Usage: set-harbor-dns.sh [--check]
#   --check  report drift and exit 1; change nothing
set -uo pipefail
cd "$(dirname "$0")/.."
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${AWS_PROFILE:=hello-openshift-sbx}"; export AWS_PROFILE
REGION="${AWS_REGION:-eu-central-2}"

ZONE_ID=$(cd terraform/2-cluster && terraform output -raw harbor_private_zone_id 2>/dev/null)
HOST=$(cd terraform/2-cluster && terraform output -raw harbor_registry_host 2>/dev/null)
HOST=${HOST%.}
[ -z "$ZONE_ID" ] && { echo "!! no harbor_private_zone_id output -- apply terraform/2-cluster first"; exit 1; }
[ -z "$HOST" ] && { echo "!! no harbor_registry_host output -- apply terraform/2-cluster first"; exit 1; }
echo "  zone: $ZONE_ID  ($HOST)"

# the Service publishes its load balancer's DNS name in status
ELB_DNS=$(oc -n harbor get svc harbor-registry-elb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
[ -z "$ELB_DNS" ] && { echo "!! the harbor-registry-elb Service has no load balancer yet"; exit 1; }
echo "  elb : $ELB_DNS"

# an ALIAS record needs the ELB's canonical hosted zone, not the account's
ELB_ZONE=$(aws elb describe-load-balancers --region "$REGION" \
  --query "LoadBalancerDescriptions[?DNSName=='$ELB_DNS'].CanonicalHostedZoneNameID" --output text 2>/dev/null)
if [ -z "$ELB_ZONE" ] || [ "$ELB_ZONE" = "None" ]; then
  echo "!! could not resolve the ELB's canonical hosted zone id"; exit 1
fi
echo "  elb canonical zone: $ELB_ZONE"

CURRENT=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${HOST}.'].AliasTarget.DNSName" --output text 2>/dev/null)
CURRENT=${CURRENT%.}
if [ "$CURRENT" = "$ELB_DNS" ]; then
  echo "  => already correct"
  exit 0
fi
echo "  current record: ${CURRENT:-<none>}"

if [ "$CHECK" -eq 1 ]; then
  echo "  => DRIFT (run without --check to upsert)"; exit 1
fi

# apex of the zone, so it must be an A/ALIAS -- CNAME is illegal at a zone apex
BATCH=$(python3 -c '
import json,sys
host,elb,zone=sys.argv[1:4]
print(json.dumps({"Comment":"harbor registry endpoint -> internal ELB",
 "Changes":[{"Action":"UPSERT","ResourceRecordSet":{
   "Name":host,"Type":"A",
   "AliasTarget":{"HostedZoneId":zone,"DNSName":elb,"EvaluateTargetHealth":False}}}]}))' \
 "$HOST" "$ELB_DNS" "$ELB_ZONE")
if ! ID=$(aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
     --change-batch "$BATCH" --query 'ChangeInfo.Id' --output text); then
  echo "!! the Route53 UPSERT failed (see the error above)" >&2
  exit 1
fi
echo "  upserted: $ID"
echo "  => $HOST now resolves to the internal ELB inside the VPC"
