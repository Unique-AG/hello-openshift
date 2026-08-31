#!/bin/bash
set -euo pipefail

#######################################
# Bootstrap the Terraform state backend (0-bootstrap stack)
#######################################
#
# Chicken-and-egg breaker: applies the 0-bootstrap stack with local
# state (it creates the state bucket + KMS key), then migrates that
# state into the bucket it just created. All other stacks use the
# static backend files in environments/<env>/backend/ directly.
#
# Usage:
#   ./scripts/bootstrap.sh [environment]   # default: sbx
#
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACK_DIR="${PROJECT_ROOT}/terraform/0-bootstrap"

ENV="${1:-sbx}"

COMMON_TFVARS="${PROJECT_ROOT}/environments/common.tfvars"
ENV_TFVARS="${PROJECT_ROOT}/environments/${ENV}/0-bootstrap.tfvars"
BACKEND_CONFIG="${PROJECT_ROOT}/environments/${ENV}/backend/0-bootstrap.s3.tfbackend"

for f in "$COMMON_TFVARS" "$ENV_TFVARS" "$BACKEND_CONFIG"; do
  if [[ ! -f "$f" ]]; then
    echo "❌ Missing: ${f}"
    [[ "$f" == "$COMMON_TFVARS" ]] && echo "   Copy environments/common.tfvars.template and fill in the values."
    exit 1
  fi
done

# Guard against applying into the wrong AWS account
EXPECTED_ACCOUNT=$(grep '^aws_account_id' "$COMMON_TFVARS" | cut -d'"' -f2)
ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [[ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]]; then
  echo "❌ AWS account mismatch: credentials are for ${ACTUAL_ACCOUNT}, common.tfvars expects ${EXPECTED_ACCOUNT}"
  exit 1
fi
echo "✅ AWS account ${ACTUAL_ACCOUNT} verified"

cd "$STACK_DIR"

# If state already migrated, a plain init is all that's needed
if terraform init -backend-config="$BACKEND_CONFIG" >/dev/null 2>&1 && terraform state list >/dev/null 2>&1; then
  echo "✅ State already in S3 — nothing to bootstrap. Use 'make plan STACK=0-bootstrap ENV=${ENV}'."
  exit 0
fi

echo "📦 Applying 0-bootstrap with local state..."
mv backend.tf backend.tf.bak
trap 'if [[ -f backend.tf.bak ]]; then mv backend.tf.bak backend.tf; fi' EXIT
terraform init
terraform apply -var-file="$COMMON_TFVARS" -var-file="$ENV_TFVARS"

echo "📤 Migrating state to S3..."
mv backend.tf.bak backend.tf
terraform init -migrate-state -backend-config="$BACKEND_CONFIG"

echo "✅ Bootstrap complete. Deploy the rest with:"
echo "   make init apply STACK=1-foundation ENV=${ENV}"
echo "   make init apply STACK=2-cluster ENV=${ENV}   (requires TF_VAR_rhcs_token)"
