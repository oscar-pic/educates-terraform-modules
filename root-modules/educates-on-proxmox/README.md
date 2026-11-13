# educates-on-proxmox

Reference root module: a Talos Linux Kubernetes cluster on Proxmox VE, ready for Educates. It uses:

- [infrastructure/proxmox-for-educates](../../infrastructure/proxmox-for-educates/) for the VMs, Talos and Cilium;
- [infrastructure/proxmox-cluster-services](../../infrastructure/proxmox-cluster-services/) for the LoadBalancer IPs and storage (Proxmox CSI, Ceph CSI, NFS CSI).

> Work in progress. This module builds the layer below Educates; Educates itself is installed with its own installer (Educates 4). See [docs/redesign.md](../../infrastructure/proxmox-for-educates/docs/redesign.md).

## Quick start

1. Check the [requirements](../../infrastructure/proxmox-for-educates/README.md#requirements). In particular, the image datastore must allow the `Import` content type.
2. Copy an example. `*.tfvars` files are git-ignored.

   ```shell
   cp examples/single-host.tfvars.example my-cluster.tfvars   # or examples/ha.tfvars.example
   ```

3. Pass the secrets through the environment, not the file. The CSI token is created as described in [proxmox-cluster-services](../../infrastructure/proxmox-cluster-services/README.md#proxmox-csi-token).

   ```shell
   export TF_VAR_proxmox_api_token='terraform@pve!educates=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
   export TF_VAR_proxmox_csi_token_secret='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
   # export TF_VAR_ceph_csi_user_key=...   # only with Ceph CSI
   ```

4. Create the cluster:

   ```shell
   tofu init
   tofu apply -var-file=my-cluster.tfvars
   ```

5. Use it. `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>` are written here, and both are git-ignored.

   ```shell
   export KUBECONFIG=$PWD/kubeconfig-<cluster_name>.yaml TALOSCONFIG=$PWD/talosconfig-<cluster_name>
   kubectl get nodes
   talosctl health
   ```

Terraform works as well as OpenTofu.

## State

The state holds the cluster PKI and the admin credentials. Keep it in an encrypted, access-controlled backend for anything beyond a lab: add a `backend` block, or use OpenTofu state encryption.

Each cluster needs its own state: a separate directory or workspace per cluster.

## Examples

| File | Topology |
|---|---|
| [examples/single-host.tfvars.example](examples/single-host.tfvars.example) | Evaluation and labs: one Proxmox host, local storage, one Talos node (control plane that also runs workloads), Proxmox CSI |
| [examples/ha.tfvars.example](examples/ha.tfvars.example) | Production-like: three Proxmox hosts, Ceph, Proxmox HA, API VIP, 3 control-plane nodes and 3 workers, storage network, Proxmox CSI (RWO) and CephFS (RWX), Gateway API |

Day-2 operations are in [docs/upgrades.md](../../infrastructure/proxmox-for-educates/docs/upgrades.md).
