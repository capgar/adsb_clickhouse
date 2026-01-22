# outputs.tf
# Output values for connecting to and using the cluster

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_region" {
  description = "AWS region where cluster is deployed"
  value       = var.aws_region
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where workloads run"
  value       = module.vpc.private_subnet_ids
}

output "clickhouse_backup_bucket" {
  description = "S3 bucket for ClickHouse backups"
  value       = module.s3.clickhouse_backup_bucket_name
}

output "clickhouse_s3_role_arn" {
  description = "IAM role ARN for ClickHouse pods to access S3 (IRSA)"
  value       = module.clickhouse_s3_access.role_arn
}

output "clickhouse_service_account_name" {
  description = "Kubernetes service account name to use for ClickHouse pods"
  value       = module.clickhouse_s3_access.service_account_name
}

output "terraform_state_bucket" {
  description = "S3 bucket for Terraform state (configure backend after initial apply)"
  value       = module.s3.terraform_state_bucket_name
}
