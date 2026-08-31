#######################################
# Split-horizon DNS for the Harbor registry endpoint
#######################################
#
# Image pulls are made by CRI-O on the nodes and must resolve Harbor to the
# INTERNAL Classic ELB that fronts it (gitops/components/platform/harbor/
# service-registry-elb.yaml). The public name openshift.example.com resolves
# to CloudFront, which is not a registry path, so the VPC needs its own answer.
#
# SCOPED TO THE SINGLE NAME ON PURPOSE. A private zone for the parent
# openshift.example.com would shadow the whole domain inside the VPC: only
# records present in the private zone would resolve, so in-cluster calls to
# id.openshift.example.com -- Zitadel's OIDC issuer, which several backends
# validate tokens against -- would start failing. A zone for exactly
# harbor.openshift.example.com overrides that one name and nothing else.
#
# TLS still works because the ACM certificate is a wildcard for
# *.openshift.example.com and is publicly trusted, so CRI-O needs no extra CA.
#
# The ALIAS target is the Kubernetes-created ELB, which Terraform does not own,
# so the record itself is upserted by scripts/set-harbor-dns.sh once the Service
# has been given a load balancer. Only the zone lives here.

resource "aws_route53_zone" "harbor_private" {
  count = var.enable_harbor_dns ? 1 : 0

  name          = "harbor.${trimprefix(var.internal_alb_certificate_domain, "*.")}"
  comment       = "Split-horizon record for the in-cluster Harbor registry (${local.cluster_name})"
  force_destroy = true

  vpc {
    vpc_id = local.vpc_id
  }

  tags = {
    Name = "route53-${local.cluster_name}-harbor-private"
  }
}

variable "enable_harbor_dns" {
  description = "Create the private hosted zone that resolves the Harbor registry endpoint inside the VPC"
  type        = bool
  default     = true
}

output "harbor_private_zone_id" {
  description = "Route53 private hosted zone that must hold the Harbor ALIAS record"
  value       = var.enable_harbor_dns ? aws_route53_zone.harbor_private[0].zone_id : null
}

output "harbor_registry_host" {
  description = "Hostname image references should use for the Harbor registry"
  value       = var.enable_harbor_dns ? aws_route53_zone.harbor_private[0].name : null
}
