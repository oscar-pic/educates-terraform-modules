# proxmox-cluster-services

Cluster services that Educates expects from a Talos cluster on Proxmox VE (created with [proxmox-for-educates](../proxmox-for-educates/)):

- **LoadBalancer IPs.** A Cilium `CiliumLoadBalancerIPPool` plus a `CiliumL2AnnouncementPolicy`. Services of type `LoadBalancer` (the Educates ingress or gateway) get an IP from the node network, announced with ARP.
- **Storage.** One or more CSI drivers, with exactly one default StorageClass:

| Backend | Access modes | When to use it |
|---|---|---|
| **Proxmox CSI** | RWO | Default choice. Volumes are Proxmox disks on any datastore (LVM, ZFS, Ceph RBD, NFS…), hot-plugged into the VMs. Works on a single host. |
| **Ceph CSI** (RBD and/or CephFS) | RWO (RBD), RWX (CephFS) | An existing Ceph cluster, such as Proxmox's own. CephFS gives shared volumes. |
| **NFS CSI** | RWX | An existing NFS export. The Educates docs note that NFS-backed storage is not regularly tested. |

It does not install an ingress controller or cert-manager: the Educates 4 operator installs its own (Contour, cert-manager, Kyverno).

## Proxmox CSI token

Create a dedicated user and token for the plugin, with only the rights it needs (from the [plugin docs](https://github.com/sergelogvinov/proxmox-csi-plugin/blob/main/docs/install.md)):

```shell
pveum role add CSI -privs "VM.Audit VM.Config.Disk Datastore.Allocate Datastore.AllocateSpace Datastore.Audit"
pveum user add kubernetes-csi@pve
pveum aclmod / -user kubernetes-csi@pve -role CSI
pveum user token add kubernetes-csi@pve csi -privsep 1     # prints the secret
pveum aclmod / -tokens 'kubernetes-csi@pve!csi' -role CSI
```

Pass `kubernetes-csi@pve!csi` as `proxmox_csi.token_id` and the secret as `proxmox_csi_token_secret`.

The plugin finds where a node runs from the node labels `topology.kubernetes.io/region` (Proxmox cluster) and `topology.kubernetes.io/zone` (Proxmox node). `proxmox-for-educates` sets both labels.

Caveats:

- **Labels after an HA move.** The zone label is written at configuration time. After Proxmox HA moves a VM to another host, re-apply so the label follows the VM. Volumes on local datastores cannot follow a VM to another host.
- **Disks per VM.** A VM accepts a limited number of SCSI disks, which caps the number of volumes per node. Prefer more, smaller worker nodes.

## Ceph CSI

- **Ceph client.** Create a client for Kubernetes on the Ceph cluster, for example on a Proxmox node:

  ```shell
  ceph auth get-or-create client.kubernetes \
    mon 'profile rbd, allow r' osd 'profile rbd pool=kubernetes' mgr 'profile rbd pool=kubernetes'    # RBD
  ceph fs subvolumegroup create cephfs csi                                                           # CephFS
  ```

  For CephFS the client also needs `mds` and `osd` rights on the file system. See the [ceph-csi capabilities](https://github.com/ceph/ceph-csi/blob/devel/docs/capabilities.md).
- **Key.** Pass the key (`ceph auth get-key client.kubernetes`) as `ceph_csi_user_key`.
- **Kernel modules.** RBD needs the `rbd` and `libceph` kernel modules on the nodes. The `educates-on-proxmox` root module adds them when RBD is enabled.

## Usage

The root module configures the `helm` and `kubectl` providers with the new cluster's credentials. See [root-modules/educates-on-proxmox](../../root-modules/educates-on-proxmox/).

```hcl
module "cluster_services" {
  source = "github.com/educates/educates-terraform-modules.git//infrastructure/proxmox-cluster-services"

  node_count            = 1
  load_balancer         = { ip_pools = ["192.168.10.240-192.168.10.249"] }
  default_storage_class = "proxmox-local"

  proxmox_csi = {
    enabled         = true
    url             = "https://pve.example.com:8006/api2/json"
    token_id        = "kubernetes-csi@pve!csi"
    storage_classes = [{ name = "proxmox-local", datastore = "local-lvm" }]
  }
  proxmox_csi_token_secret = var.proxmox_csi_token_secret

  depends_on = [module.cluster]
}
```

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
