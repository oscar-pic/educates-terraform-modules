# educates-on-proxmox

Reference root module: a Talos Linux Kubernetes cluster on Proxmox VE, ready for Educates. It configures the providers and uses [infrastructure/proxmox-for-educates](../../infrastructure/proxmox-for-educates/) for the VMs, Talos, Cilium, LoadBalancer IPs and storage (Proxmox CSI, Ceph CSI, NFS CSI).

It builds the layer below Educates. Educates itself (Educates 4) is installed afterwards with its own installer.

## Start here

**Follow [getting-started.md](../../infrastructure/proxmox-for-educates/docs/getting-started.md)**, from preparing Proxmox to a running Educates. In short:

```shell
cp examples/single-host.tfvars.example my-cluster.tfvars     # edit it
set -a; . ~/educates/proxmox.env; set +a                     # secrets (from proxmox.env.example)
tofu init && scripts/preflight.sh --var-file my-cluster.tfvars
tofu plan -var-file=my-cluster.tfvars -out=plan.out && tofu apply plan.out
```

Terraform works as well as OpenTofu.

## Files you fill in

Everything specific to your site (IPs, names, datastores, tokens) lives in files that are never committed. The repository only has templates:

| Template | Copy to | Holds |
|---|---|---|
| [examples/single-host.tfvars.example](examples/single-host.tfvars.example) or [examples/ha.tfvars.example](examples/ha.tfvars.example) | `my-cluster.tfvars` (git-ignored) | Your [settings](#settings) |
| [proxmox.env.example](proxmox.env.example) | Outside the clone, mode 0600 | Secrets: the Proxmox tokens, the Ceph keys |
| [jump-host.env.example](jump-host.env.example) | `jump-host.env` (git-ignored) | Only with a jump host: its SSH name, work directory and tfvars file name |
| [backend_override.tf.example](backend_override.tf.example) | `backend_override.tf` (git-ignored) | Optional: the state outside the clone |

| Example | Topology |
|---|---|
| `single-host` | Evaluation and labs: one Proxmox host, local storage, one Talos VM (control plane that also runs workloads), Proxmox CSI |
| `ha` | Production-like: three Proxmox hosts with Ceph, an API VIP, 3 control-plane nodes and 3 workers, a storage network, Ceph RBD (default) and CephFS, Proxmox CSI, Gateway API CRDs |

## Settings

The settings of `my-cluster.tfvars`. Each group is documented in [`variables.tf` of the module](../../infrastructure/proxmox-for-educates/variables.tf), under the name in the last column.

| Setting | What | Module variable |
|---|---|---|
| `proxmox_endpoint`, `proxmox_insecure` | Proxmox API URL, and whether to accept a self-signed certificate | (provider) |
| `cluster_name` | Cluster name, the VM name prefix | `cluster_name` |
| `proxmox` | Datastores, pool, image download node, CPU type, tags, HA | `proxmox` |
| `talos` | Talos and Kubernetes versions, config contract, extensions, NTP, kernel modules | `talos` |
| `network` | Node network: CIDR, gateway, bridge, VLAN, MTU, DNS, API VIP | `network` |
| `storage_network` | Optional second NIC, for example to reach Ceph | `storage_network` |
| `nodes` | One entry per VM: role, Proxmox host, VM ID, IP, storage IP, size, labels | `nodes` |
| `load_balancer` | IP ranges for LoadBalancer Services | `load_balancer` |
| `storage.default_class` | The default StorageClass | `default_storage_class` |
| `storage.proxmox_csi`, `storage.ceph_csi`, `storage.nfs_csi` | Storage drivers | `proxmox_csi`, `ceph_csi`, `nfs_csi` |
| `cilium`, `gateway_api` | Cilium version and values, Gateway API CRDs | `cilium`, `gateway_api` |
| `educates_workshop_egress_fix` | Cilium policy for Educates workshop namespaces (default on) | `educates_workshop_egress_fix` |
| `client_configs_dir`, `write_client_configs` | Where to write kubeconfig and talosconfig | (root module) |

Secrets come from the environment, never from the tfvars file:

| Variable | Secret |
|---|---|
| `TF_VAR_proxmox_api_token` | `user@realm!token=secret` of the OpenTofu token |
| `TF_VAR_proxmox_csi_token_secret` | Proxmox CSI token secret |
| `TF_VAR_ceph_csi_user_key`, or `TF_VAR_ceph_csi_rbd_user_key` and `TF_VAR_ceph_csi_cephfs_user_key` | Ceph client keys |

## Scripts

| Script | Does |
|---|---|
| `scripts/preflight.sh` | Checks the deploying machine before an apply: tools, Proxmox API, token privileges, datastores, pool, network, internet. `--after`: whether it reaches the cluster |
| `scripts/e2e-test.sh` | Tests a deployed cluster: storage, LoadBalancer, network, the Educates workshop network and, with `--workshop`, a real Educates session. Deletes what it creates |
| `scripts/jump-host.sh` | Runs everything on a jump host over SSH (`setup`, `preflight`, `plan`, `apply`, `e2e`, `shell`) |

Each script describes its options with `--help`.

## State

The state holds the cluster PKI and the admin credentials. Keep it in an encrypted, access-controlled backend for anything beyond a lab: add a `backend` block (or `backend_override.tf`), or use OpenTofu state encryption.

Each cluster needs its own state: a separate directory or workspace per cluster.

Day-2 operations are in [operations.md](../../infrastructure/proxmox-for-educates/docs/operations.md).
