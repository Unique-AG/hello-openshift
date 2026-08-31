# Vendored from an internal terraform-modules repository (//modules/naming@v0.1.2)
# (upstream pins aws ~>5.0, which blocks the aws 6.x upgrade)
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

