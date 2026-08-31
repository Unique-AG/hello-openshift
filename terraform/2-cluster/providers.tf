provider "aws" {
  region = var.aws_region

  default_tags {
    tags = module.ctx.tags
  }
}

# us-east-1 provider for global CloudFront resources (RAM share of the VPC origin)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = module.ctx.tags
  }
}

provider "rhcs" {
  # Preferred: Red Hat service account via TF_VAR_rhcs_client_id +
  # TF_VAR_rhcs_client_secret. Legacy fallback: TF_VAR_rhcs_token.
  # Credentials come from the environment, never from a file.
  client_id     = var.rhcs_client_id
  client_secret = var.rhcs_client_secret
  token         = var.rhcs_token
  url           = "https://api.openshift.com"
}
