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

**To deploy, start with [docs/getting-started.md](docs/getting-started.md)**, from your Proxmox to a running Educates. This README is the module reference.

- Requirements: [docs/requirements.md](docs/requirements.md).
- Day-2 operations: [docs/operations.md](docs/operations.md).
- Design, decisions and open points: [docs/design.md](docs/design.md).

## Usage

The module expects its providers from the root module, as the EKS and GKE modules do:

- **`helm.template`**, without cluster access. It renders charts: Cilium into the Talos configuration, before the cluster exists, and the storage drivers.
- **`kubectl`**, configured from this module's `kubernetes` output. It applies the cluster services once the cluster passes its health check, and retries while the API settles.

See [root-modules/educates-on-proxmox](../../root-modules/educates-on-proxmox/) for a complete example.

```hcl
provider "helm" {
  alias = "template"
}

provider "kubectl" {
  host                   = module.cluster.kubernetes.host
  cluster_ca_certificate = module.cluster.kubernetes.cluster_ca_certificate
  client_certificate     = module.cluster.kubernetes.client_certificate
  client_key             = module.cluster.kubernetes.client_key
  load_config_file       = false
  apply_retry_count      = 20 # the API can still settle (and Cilium register its CRDs) after the health check
}

module "cluster" {
  source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-for-educates"

  providers = {
    proxmox       = proxmox
    talos         = talos
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
| Educates compatibility policy | `educates-allow-in-cluster`, a Cilium policy so Educates workshop pods can reach cluster DNS, services and the API despite the Educates egress NetworkPolicy. Temporary; `educates_workshop_egress_fix = false` turns it off. See [Educates workshop network policy](#educates-workshop-network-policy) |

Control-plane nodes run workloads when there are no workers. Set `allow_scheduling_on_control_planes` to override this.

## Storage

| Backend | Access modes | When to use it |
|---|---|---|
| **Proxmox CSI** | RWO | Default choice. Volumes are Proxmox disks on any datastore (LVM, ZFS, Ceph RBD, NFS…), hot-plugged into the VMs. Works on a single host. |
| **Ceph CSI** (RBD and/or CephFS) | RWO (RBD), RWX (CephFS) | An existing Ceph cluster, such as Proxmox's own. CephFS gives shared volumes. |
| **NFS CSI** | RWX | An existing NFS export. The Educates docs note that NFS-backed storage is not regularly tested. |

Exactly one StorageClass is marked as default (`default_storage_class`). Educates needs a default RWO class.

Which one should be the default:
- **With Ceph CSI, use `ceph-rbd`.** Nodes map RBD volumes directly from Ceph, with no per-VM disk limit and no dependency on the Proxmox API. Educates creates many small volumes (one or more per workshop session).
- **Without Ceph (for example a single host), use Proxmox CSI.** Mind its limit: a VM accepts about 30 SCSI disks, which caps the volumes per node.

### Proxmox CSI

The plugin uses its own Proxmox token: see [Credentials](docs/requirements.md#credentials) for its privileges and the `pveum` commands. Pass its ID as `proxmox_csi.token_id`, and its secret as `proxmox_csi_token_secret`.

The plugin runs inside the cluster, so the nodes must reach the Proxmox API on TCP 8006. Set `proxmox_csi.url` to the address the nodes use; the root module defaults it to `proxmox_endpoint`.

It finds where a node runs from the node labels `topology.kubernetes.io/region` (`proxmox.region`) and `topology.kubernetes.io/zone` (Proxmox node). This module sets both.

Caveats:

- **Labels after an HA move.** The zone label is written at configuration time. After Proxmox HA moves a VM to another host, re-apply so the label follows the VM. Volumes on local datastores cannot follow a VM to another host.
- **Disks per VM.** A VM accepts a limited number of SCSI disks, which caps the number of volumes per node. Prefer more, smaller worker nodes.

### Ceph CSI

- **Version and CPU.** ceph-csi 3.18 and later need x86-64-v3 CPUs (AVX2). On x86-64-v2 hosts, or with the default `proxmox.cpu_type` (`x86-64-v2-AES`), set `ceph_csi.version = "3.17.2"`. `scripts/preflight.sh` checks it.
- **Pools and Ceph clients.** Create them on the Ceph cluster, for example on a Proxmox node. Capabilities follow the [ceph-csi documentation](https://github.com/ceph/ceph-csi/blob/devel/docs/capabilities.md). The commands below match `examples/ha.tfvars.example`: one client, `kubernetes`, for both drivers, its key in `ceph_csi_user_key`. The CephFS capabilities use tags, so they cover the file system's data pools whatever their names.

  ```shell
  pveceph pool create kubernetes --application rbd          # RBD pool for RWO volumes
  ceph fs subvolumegroup create cephfs csi                  # subvolume group for RWX volumes
  ceph auth get-or-create client.kubernetes \
    mon 'profile rbd, allow r fsname=cephfs' \
    mgr 'profile rbd pool=kubernetes, allow rw' \
    osd 'profile rbd pool=kubernetes, allow rw tag cephfs data=cephfs, allow rwx tag cephfs metadata=cephfs' \
    mds 'allow r fsname=cephfs path=/volumes, allow rws fsname=cephfs path=/volumes/csi'
  ceph auth get-key client.kubernetes                       # -> TF_VAR_ceph_csi_user_key
  ```

  **To isolate Kubernetes in a shared Ceph**, use one client per driver (`rbd.user_id`, `cephfs.user_id`, keys in `ceph_csi_rbd_user_key` and `ceph_csi_cephfs_user_key`). Add a RADOS namespace in the RBD pool (`rbd.rados_namespace`; `rbd namespace create <pool>/<namespace>`), and a dedicated CephFS data pool (`cephfs.data_pool`; `ceph fs add_data_pool`). Then narrow the capabilities: `profile rbd pool=<pool> namespace=<namespace>` for RBD, and `allow rw pool=<data pool>` plus the subvolume group path for CephFS.

  ceph-csi creates CephFS subvolumes through the manager's `volumes` module. So the CephFS client always needs `mgr 'allow rw'` and read access to `/volumes`: restricting it to its own subvolume group alone breaks provisioning.
- **Settings.**
  - `rbd.pool`, and `rbd.rados_namespace` for a RADOS namespace;
  - `cephfs.fs_name` and `cephfs.subvolume_group`, and `cephfs.data_pool` for a dedicated data pool.
- **Keys.** `ceph auth get-key client.<name>`, passed as `TF_VAR_*` variables (see `proxmox.env.example`).
- **Storage network.** If Ceph is on its own network, give the VMs a second NIC with `storage_network` and a `storage_ip` per node. Its MTU is inherited from the bridge by default (`mtu = 1`).
- **Kernel modules.** RBD needs `rbd` and `libceph`, and the CephFS kernel mounter needs `ceph` and `libceph`. The `educates-on-proxmox` root module adds them to `talos.kernel_modules` when RBD or CephFS is enabled. They load live on running nodes, with no reboot.

## Educates workshop network policy

Educates puts a NetworkPolicy in every workshop namespace, meaning "allow all egress except the cloud metadata IP" (`ipBlock 0.0.0.0/0 except 169.254.169.254/32`). Cilium applies `ipBlock` only to traffic leaving the cluster. So that policy also blocks workshop pods from cluster DNS, Services and the Kubernetes API: sessions fail to start or to log in. Educates 4 cannot switch it off: `sessionManager.network.blockedCidrs: []` is treated as unset.

`45-educates-compat.tf` adds a Cilium policy, `educates-allow-in-cluster`, that gives in-cluster egress to pods in Educates workshop namespaces only, and repeats the Educates rule for traffic leaving the cluster. Cilium policies add up, so workshop pods get what Educates intends: everything except the metadata IP. It is on by default (`educates_workshop_egress_fix`). Turn it off once Educates handles Cilium. `scripts/e2e-test.sh` checks it.

## Things to know

- **Upgrades.** Bumping `talos.version` replaces the downloaded image, never the VMs. Upgrade the running nodes with `talosctl upgrade`, one at a time (see [docs/operations.md](docs/operations.md)).
- **`talos.config_contract`.** Keep it at the value the cluster was created with.
- **Cilium and Gateway API CRDs** are created at bootstrap. To update them later, apply and then run `talosctl upgrade-k8s` (see [docs/operations.md](docs/operations.md)).
- **`proxmox.cpu_type = "host"`** is faster, but blocks live migration between hosts with different CPUs.
- **Outputs.** The `kubeconfig` output is the admin (break-glass) credential. Treat the state file as a secret: it holds the cluster PKI.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
