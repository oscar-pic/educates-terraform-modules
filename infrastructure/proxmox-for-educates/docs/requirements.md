# Requirements: Educates on Proxmox VE

What you need before deploying Educates on Proxmox VE with these modules. Gather everything in the [checklist](#checklist) before the first `tofu apply`.

> Draft. The first deployments on real hardware will confirm or correct it.

## Topologies

| | Evaluation / lab | Production-like |
|---|---|---|
| Proxmox hosts | 1 | 3 (Proxmox cluster) |
| Talos nodes | 1 (control plane that also runs workloads) | 3 control plane + 3 or more workers |
| Storage | Local datastore (LVM-thin, ZFS, directory) | Shared datastore (Ceph RBD or other), optionally CephFS for shared volumes |
| High availability | None | Proxmox HA for the VMs, API VIP for Kubernetes |
| Example | `examples/single-host.tfvars.example` | `examples/ha.tfvars.example` |

## Proxmox VE

- **Version 8.4 or later.** The modules import the Talos disk image through the `Import` content type, as qcow2 (Proxmox does not decompress `import` downloads). Prepared and checked on 9.2.
- **An image datastore** with the `Import` content type enabled (Datacenter → Storage → *datastore* → Content). `local` works. On a Proxmox cluster, a shared datastore such as CephFS or NFS avoids one download per host.
- **A VM datastore** for VM disks, EFI disks and cloud-init drives. With Proxmox HA it must be shared (Ceph RBD, NFS, iSCSI…).
- **A resource pool** (recommended) for the cluster's VMs, created by the Proxmox administrator. Its name is an input, for example `educates` or, nested, `lab/educates`. See [Resource pool](#credentials).
- **Proxmox HA** (optional): an existing Proxmox cluster with quorum. The VMs must use shared storage to move between hosts.
- **CPU.** VMs use `x86-64-v2-AES` by default. With `host`, live migration only works between identical CPUs. Talos, Cilium, Proxmox CSI and Educates run on x86-64-v2. **ceph-csi 3.18 and later need x86-64-v3 (AVX2)**: on older CPUs, use ceph-csi 3.17.x.

## Sizing

Talos and the Kubernetes system components need about 2 vCPU and 4 GB per node. What Educates needs depends on the workshops and the number of concurrent users.

The Educates documentation suggests starting with three workers of 16–32 GB each. It prefers more, smaller workers over a few big ones, because of per-node volume limits.

| Node | vCPU | Memory | Disk |
|---|---|---|---|
| Single node (evaluation) | 8 | 32 GB | 100 GB |
| Control plane (HA) | 4 | 8 GB | 40 GB |
| Worker (HA) | 8 | 16–32 GB | 100 GB |

Workshop volumes come from the storage backend, not from the node disks.

## Credentials

Create two API tokens. Keep their secrets out of files: pass them as `TF_VAR_*` environment variables.

**1. Token for OpenTofu/Terraform.** It creates the VMs, downloads the image and, optionally, registers HA resources. Minimal privileges, checked on Proxmox VE 9.2 and against the Proxmox source:

| Path | Privileges | Why |
|---|---|---|
| `/pool/<pool>` (with `proxmox.pool`) | Role `PVEVMAdmin` | Create and manage the VMs. **Grant VM privileges on the pool, not on `/vms/<id>`:** Proxmox deletes the ACLs of `/vms/<id>` when it destroys the VM, so after a destroy per-ID privileges are gone and the cluster cannot be recreated until someone grants them again. ACLs on the pool survive, and Proxmox accepts creating a VM in the pool with `VM.Allocate` on the pool. Without a pool, `/vms/<id>` for each VM ID works, but only until the first destroy |
| `/pool/<pool>`, only with `proxmox.pool` | Role `PVEPoolAdmin` (`Pool.Allocate`, `Pool.Audit`) | Put the VMs in the pool and read it. Nothing on the parent pools. With `proxmox.create_pool`, the pool does not exist yet: grant it on the parent instead (`/pool/lab` for `lab/educates`), which propagates |
| `/storage/<vm-datastore>` | `Datastore.AllocateSpace`, `Datastore.Audit` | VM disks, EFI disks, cloud-init drives |
| `/storage/<image-datastore>` | `Datastore.AllocateTemplate`, `Datastore.AllocateSpace`, `Datastore.Audit`, `Datastore.Allocate` | Download and import the Talos image, and **delete** it when a Talos upgrade replaces it or the cluster is destroyed. On a shared datastore, `Datastore.Allocate` also allows deleting other files there. Without it, those deletions fail with HTTP 403: drop the image from the state (`tofu state rm 'module.cluster.proxmox_download_file.talos["<node>"]'`) and let the Proxmox administrator delete the file |
| `/nodes/<node>` for each node that downloads the image | `Sys.AccessNetwork`, `Sys.Audit` | Download from a URL. This lets the host fetch any URL it can reach. With a shared image datastore, one node downloads: `proxmox.image_download_node`, or else the first, in alphabetical order, of the Proxmox nodes that host VMs (which changes with the topology). Otherwise every node that hosts a VM downloads |
| `/sdn/zones/localnetwork/<bridge>` (plain Linux bridge), or `/sdn/zones/<zone>/<vnet>` (SDN VNet) | `SDN.Use` (role `PVESDNUser`) | Attach the NICs. Needed for every bridge used, including the storage network. Since Proxmox VE 8, plain bridges need it too |
| `/` | `Sys.Audit`, `Sys.Console` | Only with `proxmox.ha_enabled`: creating HA resources |

If the VM datastore and the image datastore are the same storage, one ACL with the image privileges covers both.

**Resource pool (recommended).** A pool groups the cluster's VMs in the Proxmox UI and lets you scope the token by pool instead of by VM ID. Nested pools (Proxmox VE 8.1+) such as `lab/educates` group clusters by environment.

- **An existing pool (the default).** Whoever runs Proxmox creates and keeps the pool, and its name is an input, like the VM IDs and the IPs: set `proxmox.pool`. The module puts its VMs in it, checks that it exists, and never creates, changes or deletes it, not even on destroy. The token needs `PVEPoolAdmin` on `/pool/<pool>`, and nothing on the parent pools.
- **Or a pool created by the module** (`proxmox.create_pool = true`). The module creates the last level, and deletes it on destroy after the VMs. It must not exist beforehand, and the levels above it must exist: the module never creates or changes them. Proxmox only deletes an empty pool: if someone puts other VMs in it, the destroy stops at the pool ("pool is not empty") and those VMs are left alone.

`scripts/preflight.sh` checks the pool for either case, and the token's privileges.

**Tags.** By default the module tags each VM ("talos", the cluster name, its role, plus `proxmox.tags`). Proxmox checks tags on VM creation against `/vms/<id>` only, ignoring privileges on the pool. With VM privileges on the pool only, set `proxmox.default_tags = false` and `proxmox.tags = []`: the VMs then have no tags, and the pool groups them. `scripts/preflight.sh` catches this combination.

**VM IDs.** With privileges on the pool, Proxmox does not restrict which VM IDs the token uses. Agree on a range with the Proxmox administrator and set `nodes[*].vm_id` within it.

**The Talos image.** The module only deletes the image files it downloaded, named `talos-<version>-<schematic>-nocloud-amd64.qcow2`, never other files in the image datastore.

```shell
pveum role add EducatesDatastore -privs "Datastore.AllocateSpace Datastore.Audit"
pveum role add EducatesImage     -privs "Datastore.AllocateTemplate Datastore.AllocateSpace Datastore.Audit Datastore.Allocate"
pveum role add EducatesDownload  -privs "Sys.AccessNetwork Sys.Audit"
pveum role add EducatesHA        -privs "Sys.Audit Sys.Console"          # only with Proxmox HA

pveum user add terraform@pve
pveum user token add terraform@pve educates --privsep 1                 # prints the secret

grant() { pveum acl modify "$1" --roles "$2" --users terraform@pve --tokens 'terraform@pve!educates'; }
grant /pool/<pool>                      PVEPoolAdmin    # with proxmox.pool (an existing pool)
grant /pool/<pool>                      PVEVMAdmin      # on the pool: /vms/<id> ACLs vanish on destroy
grant /storage/<vm-datastore>           EducatesDatastore
grant /storage/<image-datastore>        EducatesImage
grant /nodes/<download-node>            EducatesDownload
grant /sdn/zones/localnetwork/<bridge>  PVESDNUser
grant /                                 EducatesHA                       # only with Proxmox HA
```

A privilege-separated token (`--privsep 1`) gets the intersection of its own ACLs and its user's. So grant every ACL to both, as `grant` does. If one user holds several tokens, the user needs the union of what they need.

**2. Token for Proxmox CSI.** The cluster uses it to create and attach volumes. It needs `VM.Audit` and `VM.Config.Disk` on the cluster's VMs (grant them on the pool: ACLs on `/vms/<id>` disappear when the VMs are destroyed), and `Datastore.Allocate`, `Datastore.AllocateSpace` and `Datastore.Audit` on the volume datastore. See the [module README](../README.md#proxmox-csi-token).

No SSH access to the Proxmox hosts is needed.

## Network

| Item | Notes |
|---|---|
| Bridge (and VLAN, if any) for the nodes | For example `vmbr0`, or an SDN VNet. On a VXLAN or EVPN VNet (MTU 1450 by default), set `network.mtu = 1` so the VMs inherit the VNet MTU |
| Node subnet, gateway, DNS servers | Static addresses. No DHCP needed |
| One IP per Talos node | In the node subnet |
| One IP for the Kubernetes API VIP | Required with more than one control-plane node |
| A range of free IPs for LoadBalancer Services | 5–10 addresses in the node subnet, outside any DHCP range. The Educates ingress uses one |
| Storage network (optional) | Bridge and subnet for a second NIC, for example to reach Ceph, and one IP per node in it. No gateway needed. The token needs `SDN.Use` on that bridge too. The VMs inherit the bridge MTU |

The API VIP and the LoadBalancer IPs are announced with ARP. They must be in the same layer-2 network as the nodes, and the network must not block gratuitous ARP.

Do not filter traffic between the nodes, for example with the Proxmox firewall. Talos, etcd, the kubelet and Cilium use many ports between them.

## Where you deploy from: workstation or jump host

You run OpenTofu from one machine. During `tofu apply` that machine talks to:

- the Proxmox API;
- **every node** on the Talos API (TCP 50000);
- the Kubernetes API (TCP 6443);
- the internet, or mirrors (see [Connectivity](#from-the-workstation-or-jump-host)).

Afterwards, operating the cluster (`talosctl`, `kubectl`, the Educates CLI) needs the same access, minus the Proxmox API.

Two options meet this. They need the same [tools](#tools); only the network path differs.

| | A. Your workstation | B. A jump host |
|---|---|---|
| When | It reaches the node subnet directly: same network, or a VPN that routes the **whole** node subnet and allows TCP 50000 and 6443 | Anything else. For example, a VPN that only reaches the Proxmox web UI, or a firewall in between |
| Where the code runs | Your clone | A clone on the jump host, driven over SSH with [`scripts/jump-host.sh`](../../../root-modules/educates-on-proxmox/scripts/jump-host.sh), or by hand |
| Where state and credentials live | Your workstation | The jump host, outside the clone |

Either way:

- **Check the machine before deploying, with the preflight script.** It reads your tfvars file and checks what it can from where it runs: the tools; the Proxmox API, the token permissions, the datastores and the VM IDs; the route to the node network; free IPs; internet access. It lists what can only be checked by hand. After the first apply, `--after` checks that the machine reaches the Talos and Kubernetes APIs of every node. That answers whether a workstation behind a VPN can operate the cluster directly.

  ```shell
  cd root-modules/educates-on-proxmox && tofu init
  scripts/preflight.sh --var-file my-cluster.tfvars            # before
  scripts/preflight.sh --var-file my-cluster.tfvars --after    # after the apply
  ```

- **Avoid slow or proxied links.** Do not deploy through a SOCKS proxy or a slow VPN. The final health check uses gRPC to the nodes. Over such a link it can hang and leave the state locked; clear the lock afterwards with `tofu force-unlock <ID>`. Do not tunnel single ports either: the Talos provider and `talosctl` connect to each node's IP, so one forwarded port is not enough. To use a jump host as a router instead, forward the whole node subnet through it (for example with `sshuttle`) and run the preflight to confirm.
- **Treat the machine as privileged.** The state, `kubeconfig-<cluster>.yaml` and `talosconfig-<cluster>` give full admin access to the cluster and contain its PKI. Limit who can log in and encrypt the disk, or keep the state in a remote encrypted backend. See the root module's [State](../../../root-modules/educates-on-proxmox/README.md#state) section.

### Option A: your workstation

Follow the root module's [quick start](../../../root-modules/educates-on-proxmox/README.md#quick-start) in your clone. Keep the tfvars file and the secrets out of git: `*.tfvars` files are ignored, and secrets go in `TF_VAR_*` variables.

### Option B: a jump host

Use a small Linux machine in the node subnet, or one routed to it, with the [tools](#tools), `git` and `tmux` installed. You need an SSH login to it; the `ssh` command alone must work, for example through an alias in `~/.ssh/config`.

Keep everything site-specific outside the clone, so nothing can be committed by mistake:

```text
<work dir>/                 for example ~/educates
├── repo/                   clone of this repository, pinned to a commit, push disabled
├── site.tfvars             your values (IPs, datastores, bridge…)
├── proxmox.env             secrets, mode 0600
└── state/                  state, plans, kubeconfig and talosconfig, mode 0700
```

`scripts/jump-host.sh` drives this layout from your workstation, over SSH. Copy `jump-host.env.example` to `jump-host.env` (git-ignored) and set `JUMP_HOST` (SSH destination) and `JUMP_DIR` (work directory). The jump host and its directory are never stored in the repository. Then:

```shell
cd root-modules/educates-on-proxmox
scripts/jump-host.sh setup       # layout, clone at your current (pushed) commit, state in state/, tofu init
# on the jump host: write site.tfvars (with client_configs_dir = "<work dir>/state") and proxmox.env
scripts/jump-host.sh preflight   # checks, run on the jump host
scripts/jump-host.sh plan        # saved to state/plan.out
scripts/jump-host.sh apply       # inside tmux: an SSH drop does not stop it; run again to re-attach
scripts/jump-host.sh shell       # tmux shell with the secrets, KUBECONFIG and TALOSCONFIG loaded
scripts/jump-host.sh sync <ref>  # deploy another commit later
```

What the script does, if you prefer doing it by hand:

- **Clone, pinned, push disabled.** `git clone <repo> repo`, `git -C repo checkout <commit>`, `git -C repo remote set-url --push origin no-push`.
- **State outside the clone.** It writes a `backend_override.tf` in `root-modules/educates-on-proxmox/`. OpenTofu merges `*_override.tf` files over the configuration, and the repository ignores them.

  ```hcl
  terraform {
    backend "local" {
      path = "/home/<user>/educates/state/terraform.tfstate"
    }
  }
  ```

- **Client files outside the clone.** Set `client_configs_dir = "<work dir>/state"` in `site.tfvars`, so the kubeconfig and talosconfig land there too.
- **Secrets only in the shell that runs OpenTofu.** It loads them from `proxmox.env` with `set -a; . proxmox.env; set +a`. Do not print them: `env | grep TF_VAR` shows them too.

  ```shell
  # proxmox.env
  TF_VAR_proxmox_api_token='terraform@pve!educates=<secret>'
  TF_VAR_proxmox_csi_token_secret='<secret>'
  ```

- **`tmux` for long runs.** The first `apply` takes 10–20 minutes. If the SSH session drops outside `tmux`, the run stops halfway and may leave the state locked.
- **Plan files are secret.** A saved plan contains the secrets in clear text. The script keeps it in `state/` and deletes it after the apply.

### Tools

| Tool | Needed for | Version |
|---|---|---|
| `git` | Cloning this repository | Any |
| OpenTofu or Terraform | Deploying the cluster | ≥ 1.6 |
| `kubectl` | Using the cluster, installing Educates with Helm | Within one minor version of the cluster's Kubernetes (1.35–1.37 for 1.36) |
| `talosctl` | Health checks, Talos upgrades, diagnostics ([upgrades.md](upgrades.md)) | Same minor version as Talos (1.14) |
| Educates CLI (`educates`) | Installing Educates (`educates admin platform deploy`) and managing workshops | Same version as the Educates release |
| `helm` | Installing Educates without the Educates CLI (Helm-based installation) | 3.x or 4.x |

OpenTofu does not need the `helm` binary. The Helm provider has its own copy.

Optional extras: `jq`, `curl` and `openssl` for checks, and the `cilium` CLI for network diagnostics.

macOS and Linux, amd64 or arm64, are fine. On Windows, use WSL.

## Connectivity

All outbound traffic to the internet is HTTPS (TCP 443), except DNS and NTP. Without internet access you need a mirror for each item. See the Talos and Educates air-gapped guides.

### From the workstation or jump host

| Destination | Port | When | Why |
|---|---|---|---|
| Proxmox API (any host of the cluster) | TCP 8006 | Deploy, changes | Create VMs, download the image, HA resources |
| Every Talos node | TCP 50000 | Deploy, operations | Talos API: apply configuration, bootstrap, health, upgrades |
| Kubernetes API (VIP or single node) | TCP 6443 | Deploy, operations, Educates install | Cluster services (phase 2), `kubectl`, Educates CLI |
| `registry.opentofu.org` or `registry.terraform.io`, `github.com`, `objects.githubusercontent.com` | 443 | `tofu init` | Provider downloads |
| `factory.talos.dev` | 443 | Deploy, Talos upgrades | Builds the image schematic and its URLs |
| `helm.cilium.io` | 443 | Deploy | The Cilium chart is rendered on this machine |
| `ghcr.io` | 443 | Deploy (Proxmox CSI), Educates install | Proxmox CSI and Educates charts |
| `ceph.github.io` | 443 | Deploy, only with Ceph CSI | Ceph CSI charts |
| `raw.githubusercontent.com` | 443 | Deploy, only with NFS CSI | NFS CSI chart |
| `github.com` | 443 | Once | Educates CLI, `talosctl` and other downloads |

### From the Proxmox hosts

| Destination | Port | Why |
|---|---|---|
| `factory.talos.dev` | 443 | Each Proxmox host that runs a node downloads the Talos disk image itself (once per host, or once with a shared image datastore) |

### From the Talos nodes

| Destination | Port | Why |
|---|---|---|
| DNS servers | UDP/TCP 53 | Name resolution |
| NTP servers | UDP 123 | Time sync. Talos refuses to work with a large clock skew |
| `ghcr.io`, `registry.k8s.io`, `quay.io`, `docker.io`, `factory.talos.dev` | 443 | Container images: system components, CSI drivers, Educates, Talos installer for upgrades |
| Whatever registries the workshops pull from | 443 | Workshop images |
| `github.com` | 443 | Gateway API CRDs at bootstrap, only if Gateway API is enabled |
| `discovery.talos.dev` | 443 | Talos discovery service (optional; the cluster works without it) |
| Proxmox API | TCP 8006 | Proxmox CSI creates and attaches volumes through it. With a firewall between the node network and the Proxmox management network, open it **and** make sure the Proxmox hosts route the replies back. If the nodes reach Proxmox through another address than OpenTofu does, set `storage.proxmox_csi.url` |
| Ceph monitors and OSDs | TCP 3300, 6789, 6800–7300 | Only with Ceph CSI |
| NFS server | TCP 2049 | Only with NFS CSI |

## Storage for Kubernetes

Choose at least one backend, and make one StorageClass the default. Educates needs a default `ReadWriteOnce` class.

| Backend | Needs |
|---|---|
| Proxmox CSI (RWO, recommended) | The CSI token and a Proxmox datastore for the volumes (any type) |
| Ceph CSI, RBD (RWO) and/or CephFS (RWX) | Ceph FSID and monitor addresses reachable from the nodes (TCP 3300, 6789, 6800–7300). An RBD pool (optionally a RADOS namespace in it), and/or a CephFS file system with a subvolume group (optionally a dedicated data pool). One Ceph client for both, or one per driver, with the [capabilities ceph-csi needs](../README.md#ceph-csi), and their keys. ceph-csi 3.17.x on x86-64-v2 CPUs |
| NFS CSI (RWX) | An NFS export reachable from the nodes. Not regularly tested by Educates |

## Using Educates

These modules do not install Educates, but the cluster must be ready for it.

**DNS.** Educates needs a domain and a wildcard record `*.<domain>` pointing to the ingress LoadBalancer IP. That IP is one address of the LoadBalancer range. Every workshop session gets its own host name under that domain.

- With private IPs, create the record in a DNS zone that the users' machines resolve, usually the internal DNS.
- A public zone pointing to private IPs works too, but some resolvers filter such answers (DNS rebinding protection).

**Certificate.** Get a wildcard certificate for `*.<domain>` from one of these:

- your own certificate;
- a lab CA that Educates uses to sign (browsers must trust it);
- ACME DNS-01 with a provider Educates supports.

**Workshop users** only need a browser, and network access from it to the ingress IP on TCP 80 and 443. If a proxy or firewall sits in between:

- it must allow WebSockets;
- its idle timeout must be long, ideally about one hour. Workshop terminals keep long-lived connections open.

**Administrators and workshop authors** need:

- `kubectl` and the Educates CLI with access to the Kubernetes API (TCP 6443);
- a browser to reach the training portal.

The jump host works for this too.

## Checklist

- [ ] Proxmox VE version (≥ 8.4) and host names
- [ ] Workstation or jump host chosen; `scripts/preflight.sh` passes on it (tools, Proxmox API and token permissions, datastores, route to the node subnet, internet or mirrors)
- [ ] Resource pool for the cluster's VMs: its name (it exists; or `create_pool`), and the VM ID range agreed with the Proxmox administrator
- [ ] Terraform API token (ID and secret) with the [ACLs](#credentials), including `PVEPoolAdmin` and `PVEVMAdmin` on the pool, and `Datastore.Allocate` on the image datastore
- [ ] Proxmox CSI token (ID and secret), if Proxmox CSI is used
- [ ] VM datastore (shared, if Proxmox HA is used)
- [ ] Image datastore with `Import` content enabled
- [ ] Outbound access from the Proxmox hosts to `factory.talos.dev`
- [ ] Bridge, VLAN, subnet, gateway, DNS, NTP
- [ ] IPs: one per node, API VIP, LoadBalancer range
- [ ] Outbound access from the node subnet (or mirrors), and from the nodes to the Proxmox API (with the return route) and the storage backend
- [ ] Storage backend details (Ceph FSID, monitors, client key / NFS export)
- [ ] VM sizing, VM ID range, tags
- [ ] Domain, wildcard DNS record and certificate for Educates
- [ ] Users' network path to the ingress IP (80/443, WebSockets allowed)
