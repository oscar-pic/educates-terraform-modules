# Educates Infrastructure Deployment on Proxmox

This repository provides a complete automation framework for deploying Kubernetes clusters (K3s or RKE2) on Proxmox VE using Terraform.

## 1. Prerequisites: Local Environment (Your Desktop/Workstation)

To execute the deployment, your local machine must satisfy:

* **Terraform**: Version >= 1.15.2.
* **SSH Keys**: An SSH key pair must be generated (`ssh-keygen -t ed25519`) and available locally. The private key is used by the Proxmox provider to manage file uploads/snipets, and the public key will be injected into VMs for access.
* **Proxmox Access**: Ensure your local machine can reach the Proxmox API endpoint (HTTPS).
* **CLI Tools**: `kubectl` is recommended to interact with the cluster after deployment.

## 2. Prerequisites: Proxmox Environment

* **Permissions**: An API Token must be generated in Proxmox (`Datacenter` -> `Permissions` -> `API Tokens`). Required permissions include `PVEVMAdmin`, `PVEDatastoreAdmin`, and `PVEDataStoreAllocate`.
* **Storage**:

  * **Images & Snippets**: A datastore (e.g., `local` or `nfs-shared`) must be enabled for `ISO` and `Snippets` content. If you use local storage, the Terraform provider will use SSH to upload configuration files to each Proxmox node individually.
  * **VM Disks**: For HA clusters, use a shared datastore (Ceph/NFS/ZFS) to allow VM migration.
* **Network**:
  * **Management (`vmbr0`)**: Used for the VM default gateway and K8s API connectivity.
  * **Storage (`vmbr1`)**: Highly recommended for RKE2 clusters to isolate Ceph traffic. Automated configuration of MTU 9000 is performed for these nodes.

## 3. Configuration Variables (`variables.tf`)

### A. Provider & Connectivity

| Variable | Description |
| :--- | :--- |
| `proxmox_endpoint` | Proxmox API URL (e.g., `https://192.168.1.28:8006`) |
| `proxmox_api_token` | API Token (format: `user@pve!token=secret`) |
| `proxmox_nodes` | Array of physical node names (e.g., `["pve01", "pve02"]`) |
| `proxmox_nodes_ceph_IPs` | IP addresses of the physical nodes for Ceph traffic |
| `ssh_private_key_path` | Local path to your private key (for Proxmox host access) |

### B. OS & Storage Configuration

| Variable | Description |
| :--- | :--- |
| `cloud_image_url` | Download URL for the Ubuntu cloud image |
| `proxmox_image_filename` | Filename to store in Proxmox |
| `proxmox_images_snippets_datastore` | Map `{"name": "...", "shared": true/false}` for snippets |
| `proxmox_vms_datastore` | Map `{"name": "...", "shared": true/false}` for VM disks |

### C. Deployment & Kubernetes

| Variable | Description |
| :--- | :--- |
| `deployment_flavor` | `'single-node-k3s'`, `'rke2-cluster'`, or `'talos-cluster'` |
| `k8s_cert_strategy` | Certificate strategy (`'provided'`, `'self-signed'`, `'letsencrypt'`) |
| `k8s_apps_cert_domains` | Domains for certificates (if using Let's Encrypt) |
| `k8s_letsencrypt_email` | Admin email for Let's Encrypt |
| `k8s_letsencrypt_dns_provider_api_token` | Token for external DNS provider API |
| `k8s_api_endpoint_vip` | Virtual IP for RKE2 API load balancing (Mandatory for HA) |
| `k8s_api_cp_interface` | NIC interface for the VIP (e.g., `eth0`) |
| `k8s_cluster_token` | Cluster join token for nodes |
| `k8s_ceph_node_interface` | Network interface for Ceph traffic |
| `k8s_ceph_network_cidr` | Network range for Ceph traffic |
| `proxmox_ceph_clusterID` | Ceph cluster FSID |
| `proxmox_ceph_k8s_key` | Base64 Ceph client key |
| `k8s_gateway_api_lb_ip_range` | IP range for Gateway API LoadBalancer |
| `system_timezone` | Server timezone (e.g., `'Europe/Madrid'`) |

### D. Node Map (`kube_nodes`)

The `kube_nodes` map defines the VMs. Each entry must contain:

* `type`: Role (`single-node-k3s`, `rke2-server-bootstrap`, `rke2-server`, `rke2-agent`).
* `proxmox_host`: Index corresponding to the `proxmox_nodes` list.
* `ip_address` / `gateway`: Network configuration.
* `dns_servers`: List of DNS resolvers.
* `network_bridge` / `ceph_network_bridge`: Proxmox bridges.
* `ceph_ip_address`: Static IP for Ceph.
* `vm_user` / `vm_password` / `ssh_key_path`: OS access credentials.
* `vm_cores` / `vm_memory` / `vm_disk_size`: VM hardware specs.
* `node_labels`: K8s labels for scheduling.

## 4. Deployment Workflow

1. **Initialize**: `terraform init -reconfigure`
2. **Plan**: `terraform plan -var-file="<your_config>.tfvars" -out="cluster.tfplan"`
3. **Apply**: `terraform apply "cluster.tfplan"`

## 5. Post-Deployment

The infrastructure automatically generates a `k8s_config.yaml` file in the root directory. You can use it immediately:
`export KUBECONFIG=$(pwd)/k8s_config.yaml && kubectl get nodes`
