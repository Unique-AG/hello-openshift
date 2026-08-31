#######################################
# Peer-pods IAM (Kata pod-VMs)
#######################################
#
# The sandboxed-containers cloud-api-adaptor launches pod VMs as EC2
# instances using static credentials from the peer-pods-secret. The
# access KEY is created out-of-band (aws CLI -> Secrets Manager) so no key
# material enters Terraform state.
#
resource "aws_iam_user" "peer_pods" {
  name = "${local.cluster_name}-peer-pods"
}

resource "aws_iam_user_policy" "peer_pods" {
  name = "${local.cluster_name}-peer-pods"
  user = aws_iam_user.peer_pods.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # read-only lookups the adaptor performs
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeImages",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateTags"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        # terminate only instances the adaptor tagged as pod VMs
        Effect   = "Allow"
        Action   = ["ec2:TerminateInstances"]
        Resource = "*"
        Condition = {
          StringLike = { "aws:ResourceTag/Name" = "podvm-*" }
        }
      }
    ]
  })
}

# One-time pod-VM AMI build (osc-podvm-image-creation job). The cluster
# runs cloud-credential-operator in Manual mode (ROSA HCP), so the
# job's CredentialsRequest (peer-pods-image-creation-secret) is never
# minted automatically — the same peer-pods user carries the image-
# creation permissions and its key is copied into that secret manually.
# Statements mirror the operator's CredentialsRequest
# openshift-sandboxed-containers-aws-image (OSC 1.12).
resource "aws_iam_user_policy" "peer_pods_image_creation" {
  name = "${local.cluster_name}-peer-pods-image-creation"
  user = aws_iam_user.peer_pods.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # vmimport service role for EC2 snapshot import
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:GetRole",
          "iam:ListRolePolicies",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy"
        ]
        Resource = "arn:aws:iam::*:role/vmimport"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:GetBucketAcl"
        ]
        Resource = "arn:aws:s3:::podvm-image-*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::podvm-image-*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = "arn:aws:iam::*:role/vmimport"
        Condition = {
          StringEquals = { "iam:PassedToService" = "vmie.amazonaws.com" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CancelConversionTask",
          "ec2:CancelExportTask",
          "ec2:CreateImage",
          "ec2:CreateInstanceExportTask",
          "ec2:CreateTags",
          "ec2:DescribeConversionTasks",
          "ec2:DescribeExportTasks",
          "ec2:DescribeExportImageTasks",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeRegions",
          "ec2:ExportImage",
          "ec2:ImportInstance",
          "ec2:ImportVolume",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances",
          "ec2:ImportImage",
          "ec2:ImportSnapshot",
          "ec2:DescribeImportImageTasks",
          "ec2:DescribeImportSnapshotTasks",
          "ec2:CancelImportTask",
          "ec2:RegisterImage",
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
      }
    ]
  })
}
