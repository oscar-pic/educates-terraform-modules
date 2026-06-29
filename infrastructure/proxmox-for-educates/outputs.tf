###############################################################################
# INFRASTRUCTURE DEPLOYMENT SUMMARY
###############################################################################

output "infrastructure_summary" {
  value = <<EOT

===============================================================================
             PROXMOX + K8S BASE INFRASTRUCTURE READY
===============================================================================

VIRTUAL MACHINE STATUS:
%{ for name, vm in proxmox_virtual_environment_vm.kube_node ~}
* Node Name:    ${vm.name}
  VM ID:        ${vm.vm_id}
  K8s IP:       ${split("/", var.kube_nodes[name].ip_address)[0]}
  Ceph IP:      ${var.kube_nodes[name].ceph_ip_address != "" ? split("/", var.kube_nodes[name].ceph_ip_address)[0] : "Not assigned"}
%{ endfor ~}

KUBERNETES CONFIGURATION:
* Kubeconfig:   Saved locally as ./build/<k3s/rke2/talos>/k8s_config.yaml
* Test Cluster: Run 'kubectl --kubeconfig ./build/<k3s/rke2/talos>/k8s_config.yaml get nodes'

NEXT STEPS (MANUAL):
1. Install the Educates CLI on your local machine.
2. Execute the following command to deploy the training portal:
   
   educates cluster create --kubeconfig ./build/<k3s/rke2/talos>/k8s_config.yaml --domain <your-domain.com>

===============================================================================
EOT
  description = "Summary of the infrastructure and instructions for next steps."
}