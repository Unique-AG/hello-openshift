terraform {
  # Backend configuration is provided via
  # environments/{env}/backend/1-foundation.s3.tfbackend
  backend "s3" {}
}
