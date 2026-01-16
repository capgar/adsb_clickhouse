# modules/ebs-csi/variables.tf

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_oidc_provider_arn" {
  description = "ARN of the OIDC provider for the EKS cluster"
  type        = string
}

variable "cluster_oidc_provider_url" {
  description = "URL of the OIDC provider for the EKS cluster"
  type        = string
}
