# Sandbox environment — 1-foundation stack

environment = "sbx"

# Budget
budget_amount         = 2500 # 3-6 x m6i.2xlarge + NAT + HCP fee
budget_contact_emails = ["platform-team@example.com"]

# KMS (shorter windows for sandbox)
kms_deletion_window = 7
kms_enable_rotation = true

# Secrets Manager: allow immediate re-create in the sandbox
secrets_recovery_window_days = 0
