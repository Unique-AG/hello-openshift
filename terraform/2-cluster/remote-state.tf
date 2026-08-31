#######################################
# Upstream Stack Outputs
#######################################
#
# The only cross-stack wire: this stack consumes the foundation
# stack's outputs (workload KMS key, buckets, secret ARNs).
#
#######################################

data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "${var.environment}/foundation.tfstate"
    region = var.aws_region
  }
}
