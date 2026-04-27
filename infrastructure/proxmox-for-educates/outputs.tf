###############################################################################
# INFRASTRUCTURE DEPLOYMENT SUMMARY
###############################################################################

output "infrastructure_summary" {
  value = <<EOT

===============================================================================
             PROXMOX + K3S BASE INFRASTRUCTURE READY
===============================================================================

VIRTUAL MACHINE STATUS:
%{ for name, vm in proxmox_virtual_environment_vm.kube_node ~}
* Node Name:    ${vm.name}
  VM ID:        ${vm.vm_id}
  Internal IP:  ${vm.ipv4_addresses[1][0]}
%{ endfor ~}

KUBERNETES CONFIGURATION:
* Kubeconfig:   Saved locally as ./k8s_config.yaml
* Test Cluster: Run 'export KUBECONFIG=./k8s_config.yaml && kubectl get nodes'

NEXT STEPS (MANUAL):
1. Install the Educates CLI on your local machine.
2. Execute the following command to deploy the training portal:
   
   educates cluster create --kubeconfig ./k8s_config.yaml --domain <your-domain.com>

===============================================================================
EOT
  description = "Summary of the infrastructure and instructions for next steps."
}

# Separate output for easy copy-pasting of the CLI command
output "educates_cli_template" {
  value       = "educates cluster create --kubeconfig ./k8s_config.yaml --domain <your-domain.com>"
  description = "Template command for the Educates CLI installation."
}