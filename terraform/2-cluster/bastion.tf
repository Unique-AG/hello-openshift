#######################################
# SSM Bastion (private cluster access)
#######################################
#
# The cluster API is private; this t3.micro provides the network path
# from a workstation via SSM port-forwarding — no public IP, no SSH
# keys, no inbound security-group rules:
#
#   aws ssm start-session --target <instance-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters host=api.<cluster-domain>,portNumber=443,localPortNumber=6443
#
#######################################

variable "enable_bastion" {
  description = "Provision the SSM bastion for private-cluster access"
  type        = bool
  default     = true
}

data "aws_ami" "al2023" {
  count = var.enable_bastion ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_role" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name = "${local.cluster_name}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count = var.enable_bastion ? 1 : 0

  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name = "${local.cluster_name}-bastion"
  role = aws_iam_role.bastion[0].name
}

resource "aws_security_group" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name        = "${local.cluster_name}-bastion"
  description = "SSM bastion: egress only, no inbound"
  vpc_id      = local.vpc_id

  egress {
    description = "All egress (SSM endpoints via NAT, cluster API)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sg-${local.cluster_name}-bastion"
  }
}

resource "aws_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  ami                    = data.aws_ami.al2023[0].id
  instance_type          = "t4g.micro"
  subnet_id              = local.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bastion[0].id]
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  lifecycle {
    # most_recent AMI lookups would otherwise replace the bastion on
    # every AL2023 release — pointless churn that severs SSM tunnels
    ignore_changes = [ami]
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 10
  }

  tags = {
    Name = "ec2-${local.cluster_name}-bastion"
  }
}

output "bastion_instance_id" {
  description = "SSM bastion instance id (for aws ssm start-session)"
  value       = var.enable_bastion ? aws_instance.bastion[0].id : null
}
