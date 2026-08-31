#######################################
# S3 Buckets
#######################################
#
# S3 buckets for data storage with:
# - KMS encryption
# - Private access (no public access)
# - Versioning enabled
#
# Note: PostgreSQL, Redis, and MinIO are deployed on OpenShift
# via Kubernetes operators in the 06-applications layer.
#######################################

# S3 Bucket for Application Data
resource "aws_s3_bucket" "application_data" {
  bucket = "s3-${module.ctx.id}-application-data"

  tags = {
    Name    = "s3-${module.ctx.id}-application-data"
    Purpose = "application-data"
  }
}

resource "aws_s3_bucket_versioning" "application_data" {
  bucket = aws_s3_bucket.application_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "application_data" {
  bucket = aws_s3_bucket.application_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workload.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "application_data" {
  bucket = aws_s3_bucket.application_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "application_data" {
  count  = var.enable_s3_lifecycle ? 1 : 0
  bucket = aws_s3_bucket.application_data.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = var.s3_transition_to_ia_days
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = var.s3_transition_to_glacier_days
      storage_class = "GLACIER"
    }
  }
}

# S3 Bucket for AI/ML Data
resource "aws_s3_bucket" "ai_data" {
  bucket = "s3-${module.ctx.id}-ai-data"

  tags = {
    Name    = "s3-${module.ctx.id}-ai-data"
    Purpose = "ai-data"
  }
}

resource "aws_s3_bucket_versioning" "ai_data" {
  bucket = aws_s3_bucket.ai_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ai_data" {
  bucket = aws_s3_bucket.ai_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.workload.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "ai_data" {
  bucket = aws_s3_bucket.ai_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "ai_data" {
  count  = var.enable_s3_lifecycle ? 1 : 0
  bucket = aws_s3_bucket.ai_data.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {}

    transition {
      days          = var.s3_transition_to_ia_days
      storage_class = "STANDARD_IA"
    }
  }

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = var.s3_transition_to_glacier_days
      storage_class = "GLACIER"
    }
  }
}
