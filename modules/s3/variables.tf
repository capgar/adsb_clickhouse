# modules/s3/variables.tf

variable "cluster_name" {
  description = "Name of the EKS cluster (used for bucket naming)"
  type        = string
}
