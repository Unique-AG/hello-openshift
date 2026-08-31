terraform {
  # Backend configuration is loaded from backend-config.hcl
  # First run: terraform init (local state) - bootstrap.sh handles this
  # After apply: terraform init -migrate-state -backend-config=environments/sbx/backend-config.hcl
  backend "s3" {
    # Backend configuration is provided via environments/{env}/backend-config.hcl
  }
}
