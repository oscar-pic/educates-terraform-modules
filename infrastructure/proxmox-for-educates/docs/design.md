# Design: Educates on Proxmox VE

How the Proxmox modules are built, and why. To deploy, start with [getting-started.md](getting-started.md).

## Goals

1. **Talos Linux only.** One distribution, one upgrade procedure. A single node covers small setups: the control plane also runs workloads.
2. **Works on one Proxmox host with local storage.** HA, Ceph and a storage network are optional.
3. **Proxmox API only.** No SSH to the hypervisors, and nothing installed on them.
4. **Day-2 operations are part of the design.** Configuration changes reach running nodes. Kubernetes upgrades are declarative. Talos upgrades never recreate VMs.
5. **Same layout as the EKS and GKE modules.** Providers are configured in the root module.
6. **Scope: the layer below Educates.** The modules deliver the cluster and what Educates 4 expects from it. Educates is installed with its own installer.

## Architecture

```text
root-modules/educates-on-proxmox          providers, wiring, examples, scripts (preflight, e2e test, jump host)
 └─ infrastructure/proxmox-for-educates   VMs + Talos + Cilium, then LoadBalancer IPs + storage drivers
```

One `infrastructure/<provider>-for-educates` module leaves the cluster ready for Educates. One `root-modules/educates-on-<provider>` configures the providers and composes it. Inside the module, the files run in two stages.

**Cluster (files `10-` to `30-`):**

- **Image.** The Talos Image Factory builds a schematic (extensions, kernel arguments) and serves the `nocloud` disk image. Proxmox downloads it as qcow2 through the API (`proxmox_download_file`, `import` content). The VMs import their disk from it once: a new Talos version only replaces the downloaded file.
- **Network bootstrap.** Proxmox's cloud-init drive gives each VM its addresses. Talos reads it on the `nocloud` platform, at boot. No custom ISO, and no secrets on Proxmox storage.
- **Machine configuration.** Generated with a pinned config contract (`talos.config_contract`), in the multi-document format of Talos 1.14. `talos_machine` applies it over the Talos API, and again on every change.
- **Bootstrap and upgrades.** `talos_cluster` bootstraps etcd and owns Kubernetes upgrades: changing `kubernetes_version` runs `upgrade-k8s`. `talos_machine` ignores Kubernetes image drift, so it never races those upgrades.
- **Health.** `talos_cluster_health` closes the stage: etcd, API server, every node.
- **CNI.** Cilium is rendered with `helm_template` into a Talos inline manifest, so nodes come up with networking. There is no kube-proxy. Nodes reach the API through KubePrism (`localhost:7445`), not one control-plane IP.
- **API VIP.** A Talos `Layer2VIPConfig` shares the API address between control-plane nodes, with no external load balancer. etcd and the kubelet are pinned to the node network, so a second NIC never changes the cluster membership.
- **Topology labels.** `topology.kubernetes.io/region` is the Proxmox cluster, and `topology.kubernetes.io/zone` is the Proxmox node. Proxmox CSI needs them.
- **Optional:** Gateway API CRDs (a Talos external manifest) with Cilium's Gateway API controller; Proxmox HA resources; a storage network.

**Cluster services (files `40-` to `50-`)**, applied once the cluster is healthy: charts rendered with `helm_template` and applied object by object with the `kubectl` provider, which retries while the API settles:

- **LoadBalancer IPs.** A `CiliumLoadBalancerIPPool` and a `CiliumL2AnnouncementPolicy`.
- **Storage.** One or more drivers, with exactly one default StorageClass:
  - **Proxmox CSI.** Volumes are Proxmox disks attached to the VMs, on any datastore. Use it without Ceph. A VM accepts about 30 SCSI disks.
  - **Ceph CSI.** RBD (RWO) and CephFS (RWX) on an existing Ceph cluster. With Ceph, use RBD as the default: there is no per-VM disk limit.
  - **NFS CSI.** RWX on an existing export.
- **Educates compatibility.** A Cilium policy for Educates workshop namespaces (see below).

## What the cluster offers to Educates

| Educates 4 expects | Provided by |
|---|---|
| A Kubernetes version the installer accepts (`>= 1.31`) | Talos, `talos.kubernetes_version` |
| A default `ReadWriteOnce` StorageClass | Ceph RBD with Ceph, Proxmox CSI without it; exactly one default |
| `LoadBalancer` Services on 80/443 for the bundled Contour (or a gateway) | Cilium LB IPAM and L2 announcements, `load_balancer.ip_pools` |
| A wildcard DNS record `*.<domain>` pointing to the ingress IP | The user. The ingress IP comes from the pool, and is pinned on the Envoy Service |
| Pod Security: Talos defaults to `baseline` | Unchanged. Educates labels its own namespaces `privileged` where needed |
| Workshop pods reaching cluster DNS and the API despite the Educates NetworkPolicy | `educates_workshop_egress_fix` |
| Optional: Gateway API CRDs, for Educates' upcoming Gateway API support | `gateway_api` |
| Cluster credentials | Root module outputs and the `kubeconfig` file |

The tested Educates configuration on this cluster is `EducatesConfig` in `Managed` mode: bundled Contour as `LoadBalancer`, `StaticCertificate`, and bundled Kyverno. See [getting-started.md](getting-started.md#5-install-educates).

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Distribution | Talos only | One upgrade procedure; immutable, API-managed nodes |
| Machine config delivery | Talos API (`talos_machine`), not an ISO | Changes reach running nodes; no secrets on Proxmox storage |
| Talos config contract | Pinned, separate from the Talos version | Upgrading Talos must not rewrite every node's configuration |
| CNI | Cilium as a Talos inline manifest | Nodes are Ready right after bootstrap |
| Talos OS upgrades | `talosctl upgrade`, one node at a time | Upgrading every node from one `for_each` in parallel can lose etcd quorum |
| Kubernetes upgrades | `talos_cluster.kubernetes_version` | `upgrade-k8s`, with health gating |
| Node reboots | Never by the provider (`reboot_after_update = false`) | Reboots in parallel would break etcd quorum |
| In-cluster services | Terraform providers after the cluster is healthy, not shell scripts | Idempotent; updates work |
| Storage drivers | Charts rendered with `helm_template`, applied object by object with `kubectl_manifest`; no `helm_release` | The kubectl provider retries through a short API outage after bootstrap. An interrupted Helm release stays `pending-install` and blocks every later apply |
| Educates installation | Out of scope: its own installer | This work is the layer below |
| Ingress | Not installed here: Educates 4 bundles Contour (and later agentgateway) | One owner per component |
| Resource pool | An existing pool by default; creating its last level is optional | Pools often belong to the Proxmox administrator; ACLs on the pool survive VM destroys |
| Proxmox HA | Optional, off in the examples | It needs `Sys.Console` on `/`; spread Kubernetes nodes are already redundant |
| Tooling | Plain `tofu`/`terraform` plus small shell scripts; no Makefile or PowerShell wrapper | Fewer moving parts |

## Known workarounds

Each one can be removed when its cause is fixed upstream.

- **`terraform-provider-talos` v0.12.0** ([#420](https://github.com/siderolabs/terraform-provider-talos/issues/420)): without `image`, `talos_machine` tries an OS upgrade to an empty image on create. The module sets `image`, ignores later changes, and sets `drain_on_upgrade = false`.
- **Proxmox VE 9.2** ([bug 7864](https://bugzilla.proxmox.com/show_bug.cgi?id=7864)): tags on VM creation ignore pool privileges. With pool-scoped privileges, set `default_tags = false` and `tags = []`. When a Proxmox release fixes it, restore tags in the examples, and make the `preflight.sh` check depend on the Proxmox version.
- **Educates 4 workshop NetworkPolicy on Cilium.** Its `ipBlock` egress rule blocks in-cluster traffic on Cilium, and it cannot be switched off. `45-educates-compat.tf` adds a Cilium policy that restores in-cluster egress for workshop namespaces only.
- **Cilium CRDs after the health check.** The Talos health check can pass before Cilium registers its CRDs. The `kubectl` provider retries (`apply_retry_count`).

## Open points

- Gateway API: agree with the Educates team on who installs the Gateway API CRDs once Educates bundles agentgateway, and on how to pin the gateway address (`Gateway.spec.addresses`).
- Proxmox HA: tested creating and destroying the HA resources, and a guest shutdown (Proxmox starts the VM again). Not yet tested: a real host failure.
- Tested on a standalone (nested) Proxmox VE 9.2 host: the `local` image datastore, Proxmox CSI on LVM-thin, NFS CSI, a cluster without an API VIP (one control-plane node, one worker), and Educates with a real workshop session.
- The Talos health check reports a healthy cluster before every node is `Ready` with its CNI. Consider an extra readiness gate before the cluster services.

## Possible later additions

- **People access through OIDC** (one client per cluster), keeping the admin kubeconfig as break-glass only.
- **Control-plane metrics:** bind addresses of the controller manager and scheduler for scraping. Exposing etcd metrics needs a node reboot.
- **Monitoring agents:** the node-exporter namespace needs the `privileged` Pod Security level.
