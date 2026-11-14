# proxmox-for-educates

Creates a Kubernetes cluster for Educates on Proxmox VE with Talos Linux, with the services Educates expects from the cluster.

The module covers:

- Proxmox VMs.
- Talos machine configuration, bootstrap and health check.
- Cilium as the CNI, with kube-proxy replacement.
- LoadBalancer IPs, announced with ARP (Cilium L2 announcements).
- Storage: one or more CSI drivers, with exactly one default StorageClass.
- An optional API VIP and optional Gateway API CRDs.

It uses only the Proxmox API (no SSH to the hypervisors) and needs no local tools besides OpenTofu or Terraform.

It does not install an ingress controller or cert-manager: the Educates 4 operator installs its own (Contour, cert-manager, Kyverno).

Before you start, see [docs/requirements.md](docs/requirements.md): Proxmox, network, credentials, and the machine you deploy from. The design, its decisions and the open points are in [docs/redesign.md](docs/redesign.md). Upgrades and other day-2 tasks are in [docs/upgrades.md](docs/upgrades.md).

## Usage

The module expects its providers from the root module, as the EKS and GKE modules do:

- **`helm.template`**, without cluster access. It renders the Cilium chart into the Talos configuration, before the cluster exists.
- **`helm` and `kubectl`**, configured from this module's `kubernetes` output. They install the cluster services once the cluster passes its health check.

See [root-modules/educates-on-proxmox](../../root-modules/educates-on-proxmox/) for a complete example.

```hcl
provider "helm" {
  alias = "template"
}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.kubernetes.host
    cluster_ca_certificate = module.cluster.kubernetes.cluster_ca_certificate
    client_certificate     = module.cluster.kubernetes.client_certificate
    client_key             = module.cluster.kubernetes.client_key
  }
}

provider "kubectl" {
  host                   = module.cluster.kubernetes.host
  cluster_ca_certificate = module.cluster.kubernetes.cluster_ca_certificate
  client_certificate     = module.cluster.kubernetes.client_certificate
  client_key             = module.cluster.kubernetes.client_key
  load_config_file       = false
}

module "cluster" {
  source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-for-educates"

  providers = {
    proxmox       = proxmox
    talos         = talos
    helm          = helm
    helm.template = helm.template
    kubectl       = kubectl
  }

  cluster_name = "educates"
  network = {
    cidr    = "192.168.10.0/24"
    gateway = "192.168.10.1"
  }
  nodes = {
    cp-01 = { role = "controlplane", proxmox_node = "pve", ip = "192.168.10.21", cpu = 8, memory = 32768, disk_size = 100 }
  }

  load_balancer         = { ip_pools = ["192.168.10.240-192.168.10.249"] }
  default_storage_class = "proxmox-local"
  proxmox_csi = {
    enabled         = true
    url             = "https://pve.example.com:8006/api2/json"
    token_id        = "kubernetes-csi@pve!csi"
    storage_classes = [{ name = "proxmox-local", datastore = "local-lvm" }]
  }
  proxmox_csi_token_secret = var.proxmox_csi_token_secret
}
```

## What it creates

| Resource | Notes |
|---|---|
| Talos Image Factory schematic and `nocloud` disk image (qcow2) | Downloaded once per Proxmox node, or once if `image_datastore_shared` |
| One VM per node (`<cluster_name>-<key>`) | q35/OVMF, VirtIO SCSI single, no memory ballooning. Network settings come from the Proxmox cloud-init drive. Optionally in a resource pool (`proxmox.pool`) |
| Talos machine configuration per node | Applied over the Talos API, and re-applied when it changes |
| etcd bootstrap and Kubernetes version | `talos_cluster`: changing `talos.kubernetes_version` runs `upgrade-k8s` |
| Cilium | Inline manifest: kube-proxy replacement, KubePrism, L2 announcements, optional Gateway API |
| Node labels | `topology.kubernetes.io/region` (Proxmox cluster) and `topology.kubernetes.io/zone` (Proxmox node), plus `nodes[*].labels` |
| Proxmox HA resources | Only with `proxmox.ha_enabled` |
| LoadBalancer IP pool | `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy`. Services of type `LoadBalancer` (the Educates ingress or gateway) get an IP from the node network |
| CSI drivers and StorageClasses | See [Storage](#storage). Applied after the cluster health check |

Control-plane nodes run workloads when there are no workers. Set `allow_scheduling_on_control_planes` to override this.

## Storage

| Backend | Access modes | When to use it |
|---|---|---|
| **Proxmox CSI** | RWO | Default choice. Volumes are Proxmox disks on any datastore (LVM, ZFS, Ceph RBD, NFS…), hot-plugged into the VMs. Works on a single host. |
| **Ceph CSI** (RBD and/or CephFS) | RWO (RBD), RWX (CephFS) | An existing Ceph cluster, such as Proxmox's own. CephFS gives shared volumes. |
| **NFS CSI** | RWX | An existing NFS export. The Educates docs note that NFS-backed storage is not regularly tested. |

Exactly one StorageClass is marked as default (`default_storage_class`). Educates needs a default RWO class.

### Proxmox CSI token

Create a dedicated user and token for the plugin, with only the rights it needs (from the [plugin docs](https://github.com/sergelogvinov/proxmox-csi-plugin/blob/main/docs/install.md)):

```shell
pveum role add CSI -privs "VM.Audit VM.Config.Disk Datastore.Allocate Datastore.AllocateSpace Datastore.Audit"
pveum user add kubernetes-csi@pve
pveum aclmod / -user kubernetes-csi@pve -role CSI
pveum user token add kubernetes-csi@pve csi -privsep 1     # prints the secret
pveum aclmod / -tokens 'kubernetes-csi@pve!csi' -role CSI
```

For a narrower scope, grant the role on the cluster's VMs and on the volume datastore (`/storage/<datastore>`) instead of `/`. For the VMs, use `/pool/<pool>` if `proxmox.pool` is set, or each `/vms/<id>`. Grant it to both the user and the token: a privilege-separated token gets the intersection of the two.

Pass `kubernetes-csi@pve!csi` as `proxmox_csi.token_id` and the secret as `proxmox_csi_token_secret`.

The plugin runs inside the cluster, so the nodes must reach the Proxmox API on TCP 8006. Set `proxmox_csi.url` to the address the nodes use. The root module defaults it to `proxmox_endpoint`.

The plugin finds where a node runs from the node labels `topology.kubernetes.io/region` (`proxmox.region`) and `topology.kubernetes.io/zone` (Proxmox node). This module sets both.

Caveats:

- **Labels after an HA move.** The zone label is written at configuration time. After Proxmox HA moves a VM to another host, re-apply so the label follows the VM. Volumes on local datastores cannot follow a VM to another host.
- **Disks per VM.** A VM accepts a limited number of SCSI disks, which caps the number of volumes per node. Prefer more, smaller worker nodes.

### Ceph CSI

- **Ceph client.** Create a client for Kubernetes on the Ceph cluster, for example on a Proxmox node:

  ```shell
  ceph auth get-or-create client.kubernetes \
    mon 'profile rbd, allow r' osd 'profile rbd pool=kubernetes' mgr 'profile rbd pool=kubernetes'    # RBD
  ceph fs subvolumegroup create cephfs csi                                                           # CephFS
  ```

  For CephFS the client also needs `mds` and `osd` rights on the file system. See the [ceph-csi capabilities](https://github.com/ceph/ceph-csi/blob/devel/docs/capabilities.md).
- **Key.** Pass the key (`ceph auth get-key client.kubernetes`) as `ceph_csi_user_key`.
- **Kernel modules.** RBD needs the `rbd` and `libceph` kernel modules on the nodes. Add them to `talos.kernel_modules`. The `educates-on-proxmox` root module does it when RBD is enabled.

## Things to know

- **Upgrades.** Bumping `talos.version` replaces the downloaded image, never the VMs. Upgrade the running nodes with `talosctl upgrade`, one at a time (see [docs/upgrades.md](docs/upgrades.md)).
- **`talos.config_contract`.** Keep it at the value the cluster was created with.
- **Cilium and Gateway API CRDs** are created at bootstrap. To update them later, apply and then run `talosctl upgrade-k8s` (see [docs/upgrades.md](docs/upgrades.md)).
- **`proxmox.cpu_type = "host"`** is faster, but blocks live migration between hosts with different CPUs.
- **Outputs.** The `kubeconfig` output is the admin (break-glass) credential. Treat the state file as a secret: it holds the cluster PKI.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
