#######################################
# VPC for ROSA Cluster
#######################################
#
# Creates a VPC with public and private subnets for ROSA.
# Private subnets are used for worker nodes.
# Public subnets are used for NAT gateways.
#
#######################################

# VPC
resource "aws_vpc" "main" {
  count = var.use_existing_vpc ? 0 : 1

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "vpc-${local.cluster_name}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id = aws_vpc.main[0].id

  tags = {
    Name = "igw-${local.cluster_name}"
  }
}

# Public Subnets (for NAT Gateways)
resource "aws_subnet" "public" {
  count = var.use_existing_vpc ? 0 : length(local.azs)

  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "subnet-public-${local.cluster_name}-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private Subnets (for Worker Nodes)
resource "aws_subnet" "private" {
  count = var.use_existing_vpc ? 0 : length(local.azs)

  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                              = "subnet-private-${local.cluster_name}-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Elastic IPs for NAT Gateways
# A private ROSA HCP cluster needs egress to Red Hat registries and OCM;
# single_nat_gateway trades AZ redundancy for cost in non-prod environments.
resource "aws_eip" "nat" {
  count = var.use_existing_vpc || !var.enable_nat_gateway ? 0 : (var.single_nat_gateway ? 1 : length(local.azs))

  domain = "vpc"

  tags = {
    Name = "eip-nat-${local.cluster_name}-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

# NAT Gateways
# When disabled, private subnets have no internet access — a private
# ROSA HCP install will hang without egress; disable only deliberately.
resource "aws_nat_gateway" "main" {
  count = var.use_existing_vpc || !var.enable_nat_gateway ? 0 : (var.single_nat_gateway ? 1 : length(local.azs))

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "nat-${local.cluster_name}-${local.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.main]
}

# Public Route Table
resource "aws_route_table" "public" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = {
    Name = "rt-public-${local.cluster_name}"
  }
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  count = var.use_existing_vpc ? 0 : length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# Private Route Tables (one per AZ for NAT Gateway redundancy)
resource "aws_route_table" "private" {
  count = var.use_existing_vpc ? 0 : length(local.azs)

  vpc_id = aws_vpc.main[0].id

  tags = {
    Name = "rt-private-${local.cluster_name}-${local.azs[count.index]}"
  }
}

# Private Route to NAT Gateway (only when NAT Gateway is enabled)
resource "aws_route" "private_nat" {
  count = var.use_existing_vpc || !var.enable_nat_gateway ? 0 : length(local.azs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
}

# Private Route Table Associations
resource "aws_route_table_association" "private" {
  count = var.use_existing_vpc ? 0 : length(local.azs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#######################################
# VPC Endpoints for Private Cluster
#######################################

# S3 Gateway Endpoint (free)
resource "aws_vpc_endpoint" "s3" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id            = aws_vpc.main[0].id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "vpce-s3-${local.cluster_name}"
  }
}

# Locals for VPC outputs
locals {
  vpc_id             = var.use_existing_vpc ? var.existing_vpc_id : aws_vpc.main[0].id
  private_subnet_ids = var.use_existing_vpc ? var.existing_private_subnet_ids : aws_subnet.private[*].id
}
