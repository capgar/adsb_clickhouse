# modules/ebs-csi/outputs.tf

output "ebs_csi_driver_role_arn" {
  description = "ARN of the IAM role for EBS CSI driver"
  value       = aws_iam_role.ebs_csi.arn
}

output "ebs_csi_driver_role_name" {
  description = "Name of the IAM role for EBS CSI driver"
  value       = aws_iam_role.ebs_csi.name
}
