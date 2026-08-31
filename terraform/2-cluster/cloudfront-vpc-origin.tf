#######################################
# CloudFront VPC Origin (via internal ALB)
#######################################
#
# Lets the connectivity account's CloudFront distribution
# (openshift.example.com) reach the ROSA ingress router.
#
# CloudFront VPC Origins require the target to have a security group, and
# security groups can only be attached to an NLB at creation time — the
# router-default NLB is created by the in-cluster Service without one. So,
# like hello-aws, an internal ALB (with SGs from creation) fronts the router:
#
#   CloudFront → VPC Origin → internal ALB → router NLB ENI IPs → router
#
# The ALB needs two subnets in two AZs; the sandbox VPC is single-AZ, so a
# small dedicated second subnet is created for the ALB (no NAT needed).
#
# The VPC origin is RAM-shared with the connectivity account.
#
# References:
# - https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html
# - Unique-AG/hello-aws 03-infrastructure/terraform/alb-cloudfront.tf
#######################################

variable "enable_cloudfront_vpc_origin" {
  description = "Create the internal ALB + CloudFront VPC Origin for the ROSA ingress router. Requires the cluster (and its router NLB) to exist."
  type        = bool
  default     = false
}

variable "connectivity_account_id" {
  description = "AWS account ID of the connectivity account the VPC origin is RAM-shared with"
  type        = string
  default     = null
}

variable "internal_alb_certificate_domain" {
  description = "Domain for the internal ALB certificate (e.g. *.openshift.example.com). Validation CNAME must be created in the connectivity account's example.com zone."
  type        = string
  default     = null
}

variable "internal_alb_https_enabled" {
  description = "Attach the HTTPS listener to the internal ALB. Flip to true only after the ACM certificate is ISSUED (its validation CNAME lives in the connectivity account's zone, so issuance happens after the connectivity stack is applied)."
  type        = bool
  default     = false
}

variable "alb_subnet_cidr" {
  description = "CIDR for the extra subnet that gives the internal ALB its second AZ"
  type        = string
  default     = "10.0.2.0/24"
}

# ROSA default ingress router NLB (created by the openshift-ingress Service)
data "aws_lb" "ingress_router" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  tags = {
    "kubernetes.io/service-name" = "openshift-ingress/router-default"
  }
}

# CloudFront origin-facing edge IP ranges
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

#######################################
# Second-AZ subnet for the ALB
#######################################

resource "aws_subnet" "cloudfront_alb" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  vpc_id                  = local.vpc_id
  cidr_block              = var.alb_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "subnet-private-${local.cluster_name}-cf-alb"
  }
}

resource "aws_route_table_association" "cloudfront_alb" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  subnet_id      = aws_subnet.cloudfront_alb[0].id
  route_table_id = aws_route_table.private[0].id
}

#######################################
# Security group (attached at ALB creation, required for VPC Origins)
#######################################

resource "aws_security_group" "alb_cloudfront" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  name        = "${module.ctx.id}-alb-cloudfront"
  description = "Security group for ALB used as CloudFront VPC Origin (forwards to ROSA ingress router NLB)"
  vpc_id      = local.vpc_id

  tags = {
    Name = "${module.ctx.id}-alb-cloudfront-sg"
  }
}

resource "aws_security_group_rule" "alb_cloudfront_https_ingress" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  type              = "ingress"
  description       = "Allow HTTPS from CloudFront VPC Origin"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront[0].id]
  security_group_id = aws_security_group.alb_cloudfront[0].id
}

resource "aws_security_group_rule" "alb_cloudfront_http_egress" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  type              = "egress"
  description       = "Allow HTTP outbound to the ingress router NLB"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.alb_cloudfront[0].id
}

resource "aws_security_group_rule" "alb_cloudfront_https_egress" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  type              = "egress"
  description       = "Allow HTTPS outbound to the ingress router NLB"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.alb_cloudfront[0].id
}

#######################################
# Internal ALB fronting the router NLB
#######################################

resource "aws_lb" "cloudfront" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  name               = "${module.ctx.id}-cf-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_cloudfront[0].id]
  subnets            = [local.private_subnet_ids[0], aws_subnet.cloudfront_alb[0].id]

  # Sandbox: no deletion protection so the environment can be torn down
  enable_deletion_protection       = false
  drop_invalid_header_fields       = true
  enable_http2                     = true
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${module.ctx.id}-cloudfront-alb"
  }
}

# ALB target groups cannot point at an NLB by DNS name, so target the router
# NLB's ENI private IPs (stable for the NLB's lifetime), port 80.
resource "aws_lb_target_group" "ingress_router" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  name        = "${module.ctx.id}-ing-tg"
  target_type = "ip"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = local.vpc_id

  # The router answers 503 for hosts with no matching route, and ALB matchers
  # cannot include 503 (200-499 only) — so with no catch-all route the single
  # target shows unhealthy and the ALB fails open, routing traffic anyway.
  # Once a route matching "/" exists on the router the check turns healthy.
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-499"
  }

  deregistration_delay = 30

  tags = {
    Name = "${module.ctx.id}-ingress-router-tg"
  }
}

# NLBs create one ENI per subnet/AZ; discover them via the ELB-managed
# description ("ELB net/<name>/<id>") derived from the NLB's arn_suffix.
data "aws_network_interfaces" "ingress_router_nlb" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  filter {
    name   = "description"
    values = ["ELB ${data.aws_lb.ingress_router[0].arn_suffix}"]
  }

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

data "aws_network_interface" "ingress_router_nlb" {
  count = var.enable_cloudfront_vpc_origin ? length(data.aws_network_interfaces.ingress_router_nlb[0].ids) : 0
  id    = data.aws_network_interfaces.ingress_router_nlb[0].ids[count.index]
}

resource "aws_lb_target_group_attachment" "ingress_router" {
  count = var.enable_cloudfront_vpc_origin ? length(data.aws_network_interfaces.ingress_router_nlb[0].ids) : 0

  target_group_arn = aws_lb_target_group.ingress_router[0].arn
  target_id        = data.aws_network_interface.ingress_router_nlb[count.index].private_ip
  port             = 80
}

#######################################
# ALB listeners + certificate
#######################################

# Regional certificate for TLS termination on the internal ALB. CloudFront's
# VPC origin connects with https-only and validates this cert against the
# origin domain (api.openshift.example.com). The validation CNAME must be
# added to the example.com zone in the connectivity account
# (route53_extra_cname_records) — see the acm validation output below.
resource "aws_acm_certificate" "internal_alb" {
  count = var.enable_cloudfront_vpc_origin && var.internal_alb_certificate_domain != null ? 1 : 0

  domain_name       = var.internal_alb_certificate_domain
  validation_method = "DNS"

  tags = {
    Name = "${module.ctx.id}-internal-alb-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "cloudfront_https" {
  count = var.enable_cloudfront_vpc_origin && var.internal_alb_https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.cloudfront[0].arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.internal_alb[0].arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_router[0].arn
  }
}

# HTTP listener kept for VPC-internal debugging; CloudFront itself connects
# via HTTPS only.
resource "aws_lb_listener" "cloudfront_http" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  load_balancer_arn = aws_lb.cloudfront[0].arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_router[0].arn
  }
}

#######################################
# CloudFront VPC Origin + RAM share
#######################################

resource "aws_cloudfront_vpc_origin" "internal_alb" {
  count = var.enable_cloudfront_vpc_origin ? 1 : 0

  vpc_origin_endpoint_config {
    name                   = "${module.ctx.id}-cloudfront-alb"
    arn                    = aws_lb.cloudfront[0].arn
    http_port              = 80 # Required by API, but not used when origin_protocol_policy = "https-only"
    https_port             = 443
    origin_protocol_policy = "https-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = {
    Name = "${module.ctx.id}-vpc-origin"
  }
}

# Share VPC Origin with connectivity account via AWS RAM
# IMPORTANT: CloudFront VPC Origins are GLOBAL resources - RAM sharing MUST be in us-east-1
resource "aws_ram_resource_share" "vpc_origin" {
  count                     = var.enable_cloudfront_vpc_origin ? 1 : 0
  provider                  = aws.us_east_1
  name                      = "${module.ctx.id}-cloudfront-vpc-origin-share"
  allow_external_principals = false

  tags = {
    Name = "${module.ctx.id}-vpc-origin-share"
  }
}

resource "aws_ram_resource_association" "vpc_origin" {
  count              = var.enable_cloudfront_vpc_origin ? 1 : 0
  provider           = aws.us_east_1
  resource_arn       = aws_cloudfront_vpc_origin.internal_alb[0].arn
  resource_share_arn = aws_ram_resource_share.vpc_origin[0].arn
}

resource "aws_ram_principal_association" "connectivity_account" {
  count              = var.enable_cloudfront_vpc_origin && var.connectivity_account_id != null ? 1 : 0
  provider           = aws.us_east_1
  principal          = var.connectivity_account_id
  resource_share_arn = aws_ram_resource_share.vpc_origin[0].arn

  depends_on = [aws_ram_resource_association.vpc_origin]
}

#######################################
# Outputs
#######################################

output "cloudfront_vpc_origin_id" {
  description = "ID of the CloudFront VPC Origin (referenced by the connectivity account's distribution)"
  value       = var.enable_cloudfront_vpc_origin ? aws_cloudfront_vpc_origin.internal_alb[0].id : null
}

output "internal_alb_certificate_validation" {
  description = "DNS validation record for the internal ALB certificate — create this CNAME in the connectivity account's example.com zone (route53_extra_cname_records)"
  value = var.enable_cloudfront_vpc_origin && var.internal_alb_certificate_domain != null ? [
    for dvo in aws_acm_certificate.internal_alb[0].domain_validation_options : {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  ] : null
}
