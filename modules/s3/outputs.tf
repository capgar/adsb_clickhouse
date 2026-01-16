# modules/s3/outputs.tf

output "terraform_state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "terraform_state_bucket_arn" {
  description = "ARN of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.arn
}

output "terraform_locks_table_name" {
  description = "Name of the DynamoDB table for Terraform locks"
  value       = aws_dynamodb_table.terraform_locks.name
}

output "clickhouse_backup_bucket_name" {
  description = "Name of the S3 bucket for ClickHouse backups"
  value       = aws_s3_bucket.clickhouse_backups.id
}

output "clickhouse_backup_bucket_arn" {
  description = "ARN of the S3 bucket for ClickHouse backups"
  value       = aws_s3_bucket.clickhouse_backups.arn
}
