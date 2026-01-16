# modules/clickhouse-s3-irsa/outputs.tf

output "role_arn" {
  description = "ARN of the IAM role for ClickHouse S3 access (use in ServiceAccount annotation)"
  value       = aws_iam_role.clickhouse_s3.arn
}

output "role_name" {
  description = "Name of the IAM role for ClickHouse S3 access"
  value       = aws_iam_role.clickhouse_s3.name
}

output "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount to create"
  value       = "clickhouse-s3"
}

output "service_account_namespace" {
  description = "Namespace for the Kubernetes ServiceAccount"
  value       = "clickhouse"
}
