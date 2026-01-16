# modules/s3/main.tf
# S3 buckets for Terraform state and ClickHouse backups

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.cluster_name}-terraform-state-${local.account_id}"

  tags = {
    Name        = "Terraform State"
    Description = "Stores Terraform state for ${var.cluster_name}"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDB table for Terraform state locking
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.cluster_name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform State Lock"
    Description = "Lock table for ${var.cluster_name} Terraform state"
  }
}

# S3 bucket for ClickHouse backups
resource "aws_s3_bucket" "clickhouse_backups" {
  bucket = "${var.cluster_name}-clickhouse-backups-${local.account_id}"

  tags = {
    Name        = "ClickHouse Backups"
    Description = "Backup storage for ClickHouse data"
  }
}

resource "aws_s3_bucket_versioning" "clickhouse_backups" {
  bucket = aws_s3_bucket.clickhouse_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clickhouse_backups" {
  bucket = aws_s3_bucket.clickhouse_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "clickhouse_backups" {
  bucket = aws_s3_bucket.clickhouse_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy for cost optimization
resource "aws_s3_bucket_lifecycle_configuration" "clickhouse_backups" {
  bucket = aws_s3_bucket.clickhouse_backups.id

  rule {
    id     = "transition-to-deep-archive"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 90  # Go straight to DEEP_ARCHIVE after 90 days
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}