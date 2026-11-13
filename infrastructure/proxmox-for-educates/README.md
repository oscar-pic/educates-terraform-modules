# proxmox-for-educates

Creates a Kubernetes cluster for Educates on Proxmox VE with Talos Linux.

The module covers:

- Proxmox VMs.
- Talos machine configuration, bootstrap and health check.
- Cilium as the CNI, with kube-proxy replacement and L2 LoadBalancer announcements.
- An optional API VIP and optional Gateway API CRDs.

It uses only the Proxmox API (no SSH to the hypervisors) and needs no local tools besides OpenTofu or Terraform.

The full design and the planned next phases (storage, Educates 4) are in [docs/redesign.md](docs/redesign.md). Upgrades and other day-2 tasks are in [docs/upgrades.md](docs/upgrades.md).

## Requirements

- **Proxmox VE 8.4 or later.** The datastore given as `proxmox.image_datastore` must allow the `Import` content type. For `local`, enable it under Datacenter → Storage → local → Content.
- **A Proxmox API token** whose role can create VMs, allocate disks, use the bridges and download images into the image datastore. `PVEVMAdmin` + `PVEDatastoreAdmin` + `PVESDNUser` on `/` works. Registering HA resources also needs permission to manage HA.
- **Free IPs in the node network:** one per node, one for the API VIP with several control-plane nodes, and a range for LoadBalancer services.
- **Network access from where you run OpenTofu** to the node IPs: the Talos API on port 50000 and the Kubernetes API on 6443. A slow or proxied link can make the final health check hang.
- **Internet access for the nodes** (container images, NTP, Gateway API CRDs if enabled), or mirrors for everything (see docs/upgrades.md).

## Usage

The module expects its providers from the root module. Helm is only used to render the Cilium chart, so pass a Helm provider without cluster access. See [root-modules/educates-on-proxmox](../../root-modules/educates-on-proxmox/) for a complete example.

```hcl
provider "helm" {
  alias = "template"
}

module "cluster" {
  source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-for-educates"

  providers = {
    proxmox = proxmox
    talos   = talos
    helm    = helm.template
  }

  cluster_name = "educates"
  network = {
    cidr    = "192.168.10.0/24"
    gateway = "192.168.10.1"
  }
  nodes = {
    cp-01 = { role = "controlplane", proxmox_node = "pve", ip = "192.168.10.21", cpu = 8, memory = 32768, disk_size = 100 }
  }
}
```

## What it creates

| Resource | Notes |
|---|---|
| Talos Image Factory schematic and `nocloud` disk image | Downloaded once per Proxmox node, or once if `image_datastore_shared` |
| One VM per node (`<cluster_name>-<key>`) | q35/OVMF, VirtIO SCSI single, no memory ballooning. Network settings come from the Proxmox cloud-init drive |
| Talos machine configuration per node | Applied over the Talos API, and re-applied when it changes |
| etcd bootstrap and Kubernetes version | `talos_cluster`: changing `talos.kubernetes_version` runs `upgrade-k8s` |
| Cilium | Inline manifest: kube-proxy replacement, KubePrism, L2 announcements, optional Gateway API |
| Node labels | `topology.kubernetes.io/region` (Proxmox cluster) and `topology.kubernetes.io/zone` (Proxmox node), plus `nodes[*].labels` |
| Proxmox HA resources | Only with `proxmox.ha_enabled` |

Control-plane nodes run workloads when there are no workers. Set `allow_scheduling_on_control_planes` to override this.

## Things to know

- **Upgrades.** Bumping `talos.version` replaces the downloaded image, never the VMs. Upgrade the running nodes with `talosctl upgrade`, one at a time (docs/upgrades.md).
- **`talos.config_contract`.** Keep it at the value the cluster was created with.
- **Cilium and Gateway API CRDs** are created at bootstrap. To update them later, apply and then run `talosctl upgrade-k8s` (docs/upgrades.md).
- **LoadBalancer IPs and storage** come from [proxmox-cluster-services](../proxmox-cluster-services/).
- **`proxmox.cpu_type = "host"`** is faster, but blocks live migration between hosts with different CPUs.
- **Outputs.** The `kubeconfig` output is the admin (break-glass) credential. Treat the state file as a secret: it holds the cluster PKI.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
