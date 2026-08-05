# Educates Infrastructure Deployment on Proxmox

This repository provides a production-ready, fully automated framework for deploying Kubernetes clusters across multiple flavors (**K3s**, **RKE2**, or **Talos Linux**) on Proxmox VE using Terraform.
To ensure state isolation, protect structural backend configurations, and simplify lifecycle management, all operations are wrapped into high-level orchestration tools (`Makefile` and `PowerShell`). Users do not need to alter or interact with the underlying Terraform code directly.

---

## 1. Prerequisites: Local Workstation Environment

Before executing any deployment or teardown operations, your local machine must be provisioned with the following dependencies:

* **Terraform** (`>= 1.15.2`): Core infrastructure execution engine.
* **Automation Interpreters**:
  * **GNU Make** (macOS/Linux environments): Required to run the `Makefile` wrapper layer.
  * **PowerShell Core** (Windows/macOS/Linux): Required to run the `deploy.ps1` wrapper script.
* **Cryptographic Keys**: A strong local SSH key pair must be available (e.g., `ssh-keygen -t ed25519 -f ~/.ssh/goson`). The private key is utilized by the Proxmox provider to upload assets and automated snippets, while the public key is dynamically injected into virtual instances (K3s/RKE2 Cloud-Init).
* **CLI Command Tools**:
  * `kubectl`: To interact with and manage cluster workloads post-deployment.
  * `yq`: Required to handle deep structural YAML configuration updates and template rendering.
  * `talosctl`: Strictly required if you choose the `talos` deployment flavor to administer the immutable operating system.

---

## 2. Prerequisites: Proxmox VE & Datacenter Topology

Your Proxmox VE cluster infrastructure must fulfill the following technical baseline before running the automation layer:

### A. RBAC & API Connectivity Tokens

An API Token must be provisioned via `Datacenter -> Permissions -> API Tokens`. The token identity requires explicit access or a custom role containing at least:

* `PVEVMAdmin` (VM creation, structural configuration, lifecycle management, and Cloud-Init execution).
* `PVEDatastoreAdmin` & `PVEDataStoreAllocate` (Storage volume allocation and programmatic snippet uploads).

### B. Network Architecture

The framework provisions a redundant, high-performance dual-stack network architecture:

* **Management & Control Network (`vmbr0`)**: Handles base VM operating system access, internet gateway routing, and the internal Kubernetes API traffic endpoints.
* **Storage Network (`vmbr1`)**: An isolated network layer dedicated exclusively to high-throughput Ceph cluster inter-node replication and sync. For advanced deployment flavors (`rke2` and `talos`), the system expects **MTU 9000 (Jumbo Frames)** configured on this bridge to maximize storage I/O performance.

### C. Storage Backends

The datastores below (Proxmox-level, for VM disks/ISOs/snippets) are unrelated to the Kubernetes
CSI storage backend that PVCs actually get provisioned from — the latter is selected independently
via `k8s_storage_backend` (see §3.C).

* **Shared Snippets Datastore**: A shared storage repository (e.g., `nfs-shared`) must be active across all hypervisor nodes. It **must** explicitly accept both `ISO Image` and `Snippets` content structures to allow automated Cloud-Init meta-data generation.
* **Ceph Storage Cluster** (when `k8s_storage_backend` is `ceph` or `both`): Hypervisor-level `RBD` (Block Storage) and `CephFS` (Shared File System) storage pools must be fully operational. The Ceph cluster `FSID` (Cluster UUID) and base64 authentication keys are injected at runtime to configure the dynamic Kubernetes CSI drivers automatically.
* **External NFS Server** (when `k8s_storage_backend` is `nfs` or `both`): a separate, already-existing NFS export (e.g. Synology, TrueNAS) reachable from the storage network. Terraform does not create or manage this export, only the `csi-driver-nfs` StorageClass pointing at it — see `nfs_csi_server_address`/`nfs_csi_share_path` below.

---

## 3. Configuration Variables (`*.tfvars`)

Cluster topologies and deployment strategies are managed via variable definition files located inside the `vars/` directory (e.g., `vars/k3s.tfvars`, `vars/rke2.tfvars`, `vars/talos.tfvars`).

### A. Core Connection & Authentication

| Variable | Description | Type / Example |
| :--- | :--- | :--- |
| `deployment_flavor` | Target cluster orchestration software. | `'k3s'`, `'rke2'`, or `'talos'` |
| `proxmox_endpoint` | The HTTPS secure API endpoint URL of your Proxmox environment. | `[https://192.168.60.34:8006/](https://192.168.60.34:8006/)` |
| `proxmox_api_token` | Formatted credential token string for secure provider auth. | `user@pve!TokenName=SecretSecret` |
| `proxmox_nodes` | Ordered array string specifying targeted physical hypervisors. | `["pve-lab-01", "pve-lab-02", "pve-lab-03"]` |
| `ssh_private_key_path` | Path to the private key used for infrastructure management. | `"~/.ssh/goson"` |

### B. Automated Cloud-Image Provisioning

| Variable | Description | Default / Example |
| :--- | :--- | :--- |
| `proxmox_image_url` | Remote HTTPS source URL to fetch the base Linux cloud image. | Cloud-Init Ubuntu image URL |
| `proxmox_image_filename` | Expected local filename for the stored template disk image. | `"ubuntu-24-cloud.img"` |

### C. Storage & Advanced Certificate Strategies

| Variable | Description | Type / Example |
| :--- | :--- | :--- |
| `proxmox_images_snippets_datastore` | Storage configuration target mapping for scripts and snippets. | `{"name": "nfs-shared", "shared": true}` |
| `proxmox_vms_datastore` | Storage configuration target mapping for virtual machine disks. | `{"name": "ceph-shared", "shared": true}` |
| `k8s_storage_backend` | Which K8s CSI storage backend(s) to install for PVCs. Not used by `k3s`. | `'ceph'` (default, RBD+CephFS), `'nfs'`, or `'both'` |
| `proxmox_ceph_clusterID` | Unique Ceph Cluster UUID (`FSID`). Required when `k8s_storage_backend` is `ceph`/`both`. | `"80a345ca-6a31-4abb-a443-5b3f5efc41d7"` |
| `proxmox_ceph_k8s_key` | Base64-encoded authentication key for the `client.kubernetes` user. Required when `k8s_storage_backend` is `ceph`/`both`. | `AQDQOg9q...==` |
| `nfs_csi_version` | `csi-driver-nfs` Helm chart version. | `"4.13.4"` |
| `nfs_csi_server_address` | IP/hostname of the external NFS server. Required when `k8s_storage_backend` is `nfs`/`both`. | `"10.10.60.10"` |
| `nfs_csi_share_path` | Export path used as the root for dynamic per-PVC subdirectory provisioning. Required when `k8s_storage_backend` is `nfs`/`both`. | `"/volume1/k8s"` |
| `nfs_csi_mount_options` | Mount options applied to the NFS StorageClass. | `["nfsvers=4.1"]` |
| `k8s_cert_strategy` | Certificate issuing automation logic. | `'self-signed'`, `'provided'`, or `'letsencrypt'` |
| `k8s_certs_path` | Local workspace relative path containing custom TLS keys. | `"./certs"` |
| `k8s_apps_cert_domains` | Target domains for routing rules (Required for Let's Encrypt). | `["*.k3s-apps.lab.inet"]` |
| `k8s_letsencrypt_email` | Administrative email for ACME certificate renewal alerts. | `"admin@k3s-apps.lab.inet"` |
| `system_timezone` | Server hardware and OS instance regional timezone definition. | `"Europe/Madrid"` |

### D. Multi-Node Cluster & High Availability Network Variables

| Variable | Description | Default / Example |
| :--- | :--- | :--- |
| `k8s_api_endpoint_vip` | Virtual IP serving as the resilient HA entry point for the API Server. | `"192.168.60.200"` |
| `k8s_api_cp_interface` | Target physical/virtual OS network interface to bind the API VIP. | `"eth0"` |
| `k8s_cluster_token` | Secure shared cluster token used to register agent nodes into control planes. | Private secure string |
| `k8s_ceph_node_interface` | Target OS network interface bound to the isolated Ceph network layer. | `"eth1"` |
| `k8s_ceph_network_cidr` | Network CIDR block representing the dedicated Ceph backend storage network. | `"10.10.60.0/24"` |
| `k8s_gateway_api_lb_ip_range`| Dedicated CIDR / IP range allocated for the Gateway API LoadBalancer. | `"192.168.60.53/32"` |

### E. Talos Specific Platform Variables

| Variable | Description | Example |
| :--- | :--- | :--- |
| `talos_cluster_name` | Administrative identifier representing the Talos topology. | `"talos-prod-01"` |
| `talos_compiled_version` | Direct Talos OS immutability release version tag. | `"v1.13.5"` |
| `talos_compiled_extensions` | Array specifying kernel extensions built into the system image. | `["qemu-guest-agent", "intel-ucode"]` |

---

## 4. Architectural Guardrails (Safety Engine)

The framework includes hardcoded architectural guardrails built directly into its validation phase via pre-execution lifecycles:

* **High-Availability VIP Check (`validate_rke2_ha_requirements`)**: If `deployment_flavor` is configured to `rke2` and the `kube_nodes` topology counts more than one Control Plane node (`rke2-server` or `rke2-server-bootstrap`), the system **enforces** that `k8s_api_endpoint_vip` must not be empty.
* If the VIP is missing, execution terminates immediately before connecting to Proxmox, outputting a critical deployment error to protect cluster quorum stability:

    CRITICAL ARCHITECTURE ERROR:
    The deployment flavor is set to 'rke2' with multiple Control Plane nodes,
    but the 'k8s_api_endpoint_vip' variable is empty.

---

## 5. Node Typology Definition Matrix (`kube_nodes`)

The `kube_nodes` map acts as the complete definitive blueprint for your topology. Each key represents a unique virtual instance configured on Proxmox VE:

    kube_nodes = {
      "cp-01" = {
        type                = "talos-controlplane-bootstrap" # Options: k3s-single-node, rke2-server-bootstrap, rke2-server, rke2-agent, talos-controlplane-bootstrap, talos-controlplane, talos-worker
        proxmox_host        = 0                              # Matches index position inside the 'proxmox_nodes' array
        ip_address          = "192.168.60.46/24"             # Management Network CIDR Allocation
        gateway             = "192.168.60.1"
        dns_servers         = ["192.168.60.32"]
        network_bridge      = "vmbr0"
        ceph_ip_address     = "10.10.60.46/24"               # Isolated Storage Network CIDR Allocation
        ceph_network_bridge = "vmbr1"
        vm_user             = ""                             # Leave empty ("") when using immutable Talos Linux
        vm_password         = ""                             # Leave empty ("") when using immutable Talos Linux
        ssh_key_path        = ""                             # Leave empty ("") when using immutable Talos Linux
        vm_cores            = 4
        vm_memory           = 16384                          # Defined in Megabytes
        vm_disk_size        = 40                             # Defined in Gigabytes
        node_labels         = ["flavor=talos-controlplane", "role=cp", "os=talos"]
      },
      "worker-01" = {
        type                = "talos-worker"
        proxmox_host        = 0
        ip_address          = "192.168.60.49/24"
        gateway             = "192.168.60.1"
        dns_servers         = ["192.168.60.32"]
        network_bridge      = "vmbr0"
        ceph_ip_address     = "10.10.60.49/24"
        ceph_network_bridge = "vmbr1"
        vm_user             = ""
        vm_password         = ""
        ssh_key_path        = ""
        vm_cores            = 8
        vm_memory           = 16384
        vm_disk_size        = 60
        # NOTE: 'storage-server=ceph-csi'/'storage-server=nfs-csi' are informational only — actual
        # CSI scheduling is constrained by the 'role=worker' label, not by 'storage-server'
        node_labels         = ["flavor=talos-worker", "role=worker", "os=talos", "storage-server=ceph-csi"]
      }
    }

---

## 6. Execution Workflow (Automation Wrappers)

To prevent state crossover and handle automated state migrations smoothly, **do not invoke raw Terraform commands directly**. Instead, utilize the custom orchestration scripts designed for your workstation platform.

Both wrappers use Terraform's `local` backend with an explicit `path` computed from
`build/<environment>/<k8s_cluster_name>/terraform.tfstate` — read straight out of the tfvars
file you point at with `TFVARS=<name>`, not from Terraform workspaces (none are used). There's
no separate flavor parameter either: the flavor itself is read from that same tfvars file's own
`deployment_flavor` variable, so it can never disagree with what actually gets deployed. This
means state is isolated per cluster: `talos.tfvars` and, say, `talos-on-axlab.tfvars` (different
`k8s_cluster_name`) never share state even though both deploy `talos`.

Select the tool corresponding to your operating system platform:

### Option A: Linux or macOS Systems — Using `Makefile`

All workflow tasks require the explicit invocation of the `TFVARS` variable flag (e.g. `TFVARS=talos` for `vars/talos.tfvars`). An optional `PARALLELISM=n` caps concurrent Terraform operations (e.g. `PARALLELISM=1` to serialize them).

#### 1. Analyze and Plan Infrastructure Build

Initializes the backend at the environment/cluster-scoped path (auto-migrating state if the path just changed), and writes a secured plan output artifact file:

    make plan TFVARS=talos [PARALLELISM=1]

#### 2. Execute Infrastructure Rollout (Apply)

Applies the pre-compiled deployment blueprint artifact safely to your Proxmox VE infrastructure.
*Note: Always use this specific wrapper command instead of standard vanilla terraform commands post-plan to ensure all downstream output variables remain tied to the correct state.*

    make apply TFVARS=talos [PARALLELISM=1]

#### 3. Full Infrastructure Teardown (Destroy)

Triggers a safe, un-attended full teardown sequence isolated exclusively to the specified cluster's state:

    make destroy TFVARS=talos [PARALLELISM=1]

---

### Option B: Windows Systems — Using `PowerShell Core`

The `deploy.ps1` script implements the same environment/cluster-scoped state isolation, keeping infrastructure actions completely separated -- same as the Makefile, there's no `-Flavor` parameter either. An optional `-Parallelism n` caps concurrent Terraform operations.

#### 1. Analyze and Plan Infrastructure Build

    .\deploy.ps1 -Action plan -TfVars talos [-Parallelism 1]

#### 2. Execute Infrastructure Rollout (Apply)

    .\deploy.ps1 -Action apply -TfVars talos [-Parallelism 1]

#### 3. Full Infrastructure Teardown (Destroy)

    .\deploy.ps1 -Action destroy -TfVars talos [-Parallelism 1]

#### CLI Help Dashboard

To query quick-start command examples and parameter options directly in your console:

    .\deploy.ps1 -Help

---

## 7. Post-Deployment Cluster Connectivity

Once execution reports complete, the wrapper framework automatically handles backend target outputs, formats the admin administrative credentials, and generates a local workspace connectivity file named `k8s_config.yaml` in your "\<root>/build/\<environment>/\<cluster_name>" folder.

Execute the following commands in your local workstation terminal to verify operations:

    # 1. Map your terminal session to the newly exported workspace configuration
    export KUBECONFIG=$(pwd)/build/<environment>/<cluster_name>/k8s_config.yaml

    # 2. Verify all multi-node topology objects report healthy status
    kubectl get nodes -o wide

    # 3. Confirm that Ceph CSI storage-server scheduling labels match allocations
    kubectl get nodes --show-labels

    # 4. Confirm the CSI StorageClass(es) selected via k8s_storage_backend are present
    kubectl get storageclass

    # 5. (Talos only) talosctl already defaults to the bootstrap node, no --nodes needed
    talosctl --talosconfig build/<environment>/<cluster_name>/talosconfig get members
