# Terraform stack runner.
#
#   make init  STACK=1-foundation ENV=sbx
#   make plan  STACK=2-cluster
#   make apply STACK=2-cluster        # ROSA apply takes 40-60 min
#
# 2-cluster auth (pick one):
#   export TF_VAR_rhcs_client_id=... TF_VAR_rhcs_client_secret=...   (service account, preferred)
#   export TF_VAR_rhcs_token=<token>                                 (legacy offline token)
# First-time setup of the state backend: ./scripts/bootstrap.sh <env>

ENV   ?= sbx
STACK ?= 1-foundation

DIR     := terraform/$(STACK)
COMMON  := $(CURDIR)/environments/common.tfvars
COMMON_TEMPLATE := $(CURDIR)/environments/common.tfvars.template
VARS    := -var-file=$(COMMON) -var-file=$(CURDIR)/environments/$(ENV)/$(STACK).tfvars
BACKEND := $(CURDIR)/environments/$(ENV)/backend/$(STACK).s3.tfbackend

STACKS := 0-bootstrap 1-foundation 2-cluster

.PHONY: init plan apply destroy output fmt validate lint

$(COMMON):
	$(error environments/common.tfvars not found — copy environments/common.tfvars.template and fill in the values)

init: $(COMMON)
	terraform -chdir=$(DIR) init -backend-config=$(BACKEND)

plan: $(COMMON)
	terraform -chdir=$(DIR) plan $(VARS)

apply: $(COMMON)
	terraform -chdir=$(DIR) apply $(VARS)

destroy: $(COMMON)
	terraform -chdir=$(DIR) destroy $(VARS)

output:
	terraform -chdir=$(DIR) output -json

fmt:
	terraform fmt -recursive terraform

validate:
	@for s in $(STACKS); do \
		echo "== terraform/$$s"; \
		terraform -chdir=terraform/$$s init -backend=false -input=false >/dev/null || exit 1; \
		terraform -chdir=terraform/$$s validate || exit 1; \
	done

# Mirrors the CI checks. Each tool is skipped only when genuinely absent -- a
# tool that runs and reports problems must fail the target, which the earlier
# `cmd && tool || echo "not installed"` shape silently swallowed.
lint:
	@if command -v tflint >/dev/null; then tflint --chdir=$(DIR); else echo "tflint not installed, skipping"; fi
	@if command -v trivy >/dev/null; then \
		trivy fs --scanners misconfig --severity HIGH,CRITICAL --exit-code 1 \
		  --ignorefile .trivyignore --skip-dirs '**/.terraform' \
		  --tf-vars $(COMMON_TEMPLATE),$(CURDIR)/environments/$(ENV)/$(STACK).tfvars \
		  $(DIR); \
	else echo "trivy not installed, skipping"; fi
	@if command -v gitleaks >/dev/null; then \
		gitleaks detect --source . --config scripts/gitleaks-config.toml --redact --no-banner --no-git; \
	else echo "gitleaks not installed, skipping"; fi
