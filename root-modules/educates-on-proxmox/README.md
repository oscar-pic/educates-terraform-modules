# educates-on-proxmox

Reference root module: a Talos Linux Kubernetes cluster on Proxmox VE, ready for Educates. It configures the providers and uses [infrastructure/proxmox-for-educates](../../infrastructure/proxmox-for-educates/) for the VMs, Talos, Cilium, LoadBalancer IPs and storage (Proxmox CSI, Ceph CSI, NFS CSI).

> Work in progress. This module builds the layer below Educates; Educates itself is installed with its own installer (Educates 4). See [docs/redesign.md](../../infrastructure/proxmox-for-educates/docs/redesign.md).

## Quick start

The full walk-through, from preparing Proxmox to installing Educates, is in [getting-started.md](../../infrastructure/proxmox-for-educates/docs/getting-started.md).


1. Check the [requirements](../../infrastructure/proxmox-for-educates/docs/requirements.md): Proxmox, network, the machine you deploy from (workstation or jump host), its tools and connectivity. In particular, the image datastore must allow the `Import` content type, and that machine must reach every node's Talos API.
2. Copy an example. `*.tfvars` files are git-ignored.

   ```shell
   cp examples/single-host.tfvars.example my-cluster.tfvars   # or examples/ha.tfvars.example
   ```

3. Pass the secrets through the environment, not the file. The CSI token is created as described in [proxmox-for-educates](../../infrastructure/proxmox-for-educates/README.md#proxmox-csi-token).

   ```shell
   export TF_VAR_proxmox_api_token='terraform@pve!educates=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
   export TF_VAR_proxmox_csi_token_secret='xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
   # export TF_VAR_ceph_csi_user_key=...   # only with Ceph CSI
   ```

4. Check that this machine meets the requirements, then create the cluster:

   ```shell
   tofu init
   scripts/preflight.sh --var-file my-cluster.tfvars
   tofu apply -var-file=my-cluster.tfvars
   ```

5. Use it. `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>` are written here, and both are git-ignored.

   ```shell
   export KUBECONFIG=$PWD/kubeconfig-<cluster_name>.yaml TALOSCONFIG=$PWD/talosconfig-<cluster_name>
   kubectl get nodes
   talosctl health
   ```

Terraform works as well as OpenTofu.

## Deploying from a jump host

If your workstation does not reach the node network (TCP 50000 and 6443 on every node), deploy from a jump host. `scripts/jump-host.sh` drives it over SSH: it sets up the layout, clones this repository at your pushed commit, and runs the preflight, `plan` and `apply` (inside `tmux`) there. The jump host's name and directory go in `jump-host.env` (copy `jump-host.env.example`; git-ignored). See [requirements: where you deploy from](../../infrastructure/proxmox-for-educates/docs/requirements.md#where-you-deploy-from-workstation-or-jump-host).

After the first apply, `scripts/preflight.sh --var-file <file> --after` tells whether a machine can operate the cluster directly.

## Files you fill in

Everything specific to your site (IPs, names, datastores, tokens) lives in files that are never committed. The repository only has templates:

| Template | Copy to | Holds |
|---|---|---|
| [examples/single-host.tfvars.example](examples/single-host.tfvars.example), [examples/ha.tfvars.example](examples/ha.tfvars.example) | Any `*.tfvars` (git-ignored), or outside the clone | Your values: Proxmox endpoint, datastores, network, nodes, LoadBalancer range, storage |
| [proxmox.env.example](proxmox.env.example) | Outside the clone, mode 0600 | Secrets: the Proxmox tokens, the Ceph key |
| [backend_override.tf.example](backend_override.tf.example) | `backend_override.tf` (git-ignored) | Optional: state outside the clone |
| [jump-host.env.example](jump-host.env.example) | `jump-host.env` (git-ignored) | Only with a jump host: its SSH name, work directory and tfvars file name |

## State

The state holds the cluster PKI and the admin credentials. Keep it in an encrypted, access-controlled backend for anything beyond a lab: add a `backend` block, or use OpenTofu state encryption.

Each cluster needs its own state: a separate directory or workspace per cluster.

## Examples

| File | Topology |
|---|---|
| [examples/single-host.tfvars.example](examples/single-host.tfvars.example) | Evaluation and labs: one Proxmox host, local storage, one Talos node (control plane that also runs workloads), Proxmox CSI |
| [examples/ha.tfvars.example](examples/ha.tfvars.example) | Production-like: three Proxmox hosts, Ceph, Proxmox HA, API VIP, 3 control-plane nodes and 3 workers, storage network, Proxmox CSI (RWO) and CephFS (RWX), Gateway API |

Day-2 operations are in [docs/upgrades.md](../../infrastructure/proxmox-for-educates/docs/upgrades.md).
