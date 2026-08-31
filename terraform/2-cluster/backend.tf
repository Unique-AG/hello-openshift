terraform {
  backend "s3" {
    # Backend configuration is provided via
    # environments/{env}/backend/2-cluster.s3.tfbackend
  }
}
