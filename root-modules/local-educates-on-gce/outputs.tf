output "gce" {
  value     = module.gce_for_local_educates.gce
  sensitive = true
}

output "ssh_connection" {
  value = {
    host = module.gce_for_local_educates.ssh_connection.host
    user = module.gce_for_local_educates.ssh_connection.user
  }
}

output "educates" {
  value = var.deploy_educates ? module.educates_local[0].educates : null
}
