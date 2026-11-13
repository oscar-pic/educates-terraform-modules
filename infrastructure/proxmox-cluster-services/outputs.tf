output "storage_classes" {
  description = "StorageClasses created by this module."
  value       = local.storage_classes
}

output "default_storage_class" {
  description = "Default StorageClass."
  value       = var.default_storage_class
}
