# modules/storage/outputs.tf

output "default_storage_class" {
  description = "Name of the default storage class"
  value       = kubernetes_storage_class.gp3.metadata[0].name
}

output "storage_classes" {
  description = "List of created storage class names"
  value = [
    kubernetes_storage_class.gp3.metadata[0].name,
    kubernetes_storage_class.gp3_high_iops.metadata[0].name,
    kubernetes_storage_class.gp3_retain.metadata[0].name,
  ]
}
