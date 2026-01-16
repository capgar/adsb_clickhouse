# modules/clickhouse-s3-irsa/main.tf
# IAM Role for Service Account (IRSA) for ClickHouse to access S3 backups
# This allows ClickHouse pods to write backups to S3 without storing credentials

data "aws_iam_policy_document" "clickhouse_s3_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:clickhouse:clickhouse-s3"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "clickhouse_s3" {
  name               = "${var.cluster_name}-clickhouse-s3-access"
  assume_role_policy = data.aws_iam_policy_document.clickhouse_s3_assume_role.json

  tags = {
    Name = "${var.cluster_name}-clickhouse-s3-access"
  }
}

# IAM policy for S3 backup bucket access
data "aws_iam_policy_document" "clickhouse_s3_policy" {
  statement {
    sid    = "AllowClickHouseBackups"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      var.backup_bucket_arn,
      "${var.backup_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_policy" "clickhouse_s3" {
  name        = "${var.cluster_name}-clickhouse-s3-policy"
  description = "Allows ClickHouse to access S3 backup bucket"
  policy      = data.aws_iam_policy_document.clickhouse_s3_policy.json
}

resource "aws_iam_role_policy_attachment" "clickhouse_s3" {
  policy_arn = aws_iam_policy.clickhouse_s3.arn
  role       = aws_iam_role.clickhouse_s3.name
}

# Kubernetes service account (to be created manually or via GitOps)
# This is just documentation - actual creation happens outside Terraform
# 
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: clickhouse-s3
#   namespace: clickhouse
#   annotations:
#     eks.amazonaws.com/role-arn: <output from this module>
