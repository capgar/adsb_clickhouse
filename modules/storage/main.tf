# modules/storage/main.tf
# Kubernetes StorageClass definitions for EBS volumes
# Optimized for cost and performance

# GP3 storage class (general purpose, cost-optimized)
# This is the default and recommended for most workloads
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy        = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    # GP3 defaults: 3000 IOPS, 125 MB/s throughput
    # Can be increased if needed for higher workloads
  }
}

# GP3 with higher IOPS (for ClickHouse data volumes if needed)
resource "kubernetes_storage_class" "gp3_high_iops" {
  metadata {
    name = "gp3-high-iops"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy        = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    iops      = "5000"      # Up to 16000 max for gp3
    throughput = "250"      # MB/s, up to 1000 max for gp3
  }
}

# Retain storage class for data that should persist after PVC deletion
resource "kubernetes_storage_class" "gp3_retain" {
  metadata {
    name = "gp3-retain"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy        = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
