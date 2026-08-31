provider "aws" {
  region = var.aws_region

  default_tags {
    tags = module.ctx.tags
  }
}
