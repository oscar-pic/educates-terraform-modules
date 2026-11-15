# Upgrades and day-2 operations

Commands assume `talosctl` and `kubectl` use the files written by the root module:

```shell
export TALOSCONFIG=$PWD/talosconfig-<cluster_name>
export KUBECONFIG=$PWD/kubeconfig-<cluster_name>.yaml
```

Rehearse every procedure on a test cluster first.

## Changing the configuration

Edit the variables and run `tofu apply`. `talos_machine` re-applies the new machine configuration to each node, and Talos decides whether a reboot is needed.

- **Reboots.** Some changes need one. For example, etcd extra arguments only take effect after a reboot.
- **API server restarts.** Changing the API server authentication configuration restarts the API server on each control-plane node for about 10 s.
- **Several control-plane nodes.** To change a setting that restarts components, apply with `-parallelism=1`, or reboot or patch the nodes one at a time.
- **Talos merges lists by appending.** To replace a list entry, delete the document in one patch and add it back in another. The module does this for the default `KubeNodeConfig`.
- **Do not change `talos.config_contract`.** It regenerates every node's configuration and may rotate secrets.

## Upgrading Kubernetes

1. Set `talos.kubernetes_version` to the new version.
2. Run `tofu apply`.

`talos_cluster` then runs Talos's `upgrade-k8s`: it upgrades the API server, controller manager and scheduler, then the kubelet node by node, with health checks between steps. No node reboots.

## Upgrading Talos

Talos OS upgrades reboot the node. They are done with `talosctl`, **one node per command**, so etcd never loses quorum.

1. Read the installer image for the new version. Set `talos.version` to the new version, run `tofu plan`, and take `talos_installer_image` from the plan output. Or build the URL by hand: same schematic, new tag.
2. Upgrade the control-plane nodes one by one. Do the node that currently holds the API VIP last: the VIP moves and the API keeps answering. Then upgrade the workers.

   ```shell
   talosctl -n <node-ip> upgrade --image <installer-image>
   talosctl -n <node-ip> health        # wait until healthy before the next node
   talosctl -n <cp-ip> etcd members    # after each control-plane node
   ```

   Each node takes about 2 minutes. Never upgrade several control-plane nodes at once.
3. Run `tofu apply`, so the code matches what runs. It needs `Datastore.Allocate` on the image datastore, to delete the old image. This replaces the downloaded Talos image and updates the installer image in the machine configuration. It must **not** replace any VM: if the plan shows a VM being replaced, stop.

If the nodes cannot reach the internet, mirror the installer image (`factory.talos.dev/...`) before the first upgrade. At creation time Proxmox downloads the disk image, not the nodes, so a missing mirror only shows up on the first upgrade.

## Updating Cilium or the Gateway API CRDs

Talos creates inline and external manifests at bootstrap but **does not update them**. After changing `cilium.version`, `cilium.extra_values` or `gateway_api.version`:

1. `tofu apply` stores the new manifests in the node configuration.
2. Sync them into the cluster. Always run the dry run first:

   ```shell
   talosctl -n <cp-ip> upgrade-k8s --to <current-kubernetes-version> --dry-run
   talosctl -n <cp-ip> upgrade-k8s --to <current-kubernetes-version>
   ```

   `upgrade-k8s` also **deletes** objects that are no longer in the manifests. Read the deletions in the dry run, not only the additions.
3. Cilium pods do not restart on a config change. Do a staggered rollout:

   ```shell
   kubectl -n kube-system rollout restart daemonset/cilium
   kubectl -n kube-system rollout status daemonset/cilium
   kubectl -n kube-system rollout restart deployment/cilium-operator
   ```

4. Check that the controllers processed their resources, not only that the pods are running. For example, Gateways report `Programmed` and `generation` equals `observedGeneration`.

## Draining a node by hand

Cordon, drain, reboot (or upgrade), check the etcd members on control-plane nodes, then uncordon.

```shell
kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
talosctl -n <node-ip> reboot
kubectl uncordon <node>
```

CoreDNS runs two replicas that may land on the same node. Give it a PodDisruptionBudget before relying on drains.

## Scaling

- **Adding a node.** Add it to `nodes` and apply. It joins at `talos.kubernetes_version`.
- **Going from one to three control-plane nodes.** Add two `controlplane` nodes, preferably on different Proxmox hosts, and apply. The new nodes join etcd, and the existing nodes are not changed or rebooted. This needs `network.api_vip` set **from the start**: the cluster endpoint is fixed when the cluster is created. Without a VIP it is the first node's IP, and growing then means rebuilding the cluster. If a single-node cluster may grow, give it a VIP anyway.
- **Checking control-plane failover.** Reboot the node that holds the VIP (`talosctl -n <ip> get addresses` shows it) while polling `https://<vip>:6443/version`. Any HTTP answer, including 401, means the API is up. The VIP moves to another control-plane node, and the API keeps answering.
- **Removing a worker.** Drain it first, then remove it from `nodes`.
- **Removing a control-plane node.** Remove it from etcd first (`talosctl -n <node-ip> reset --graceful`), and keep an odd number of control-plane nodes.

## Adding a storage network to a running cluster

To reach Ceph (or NFS) over a dedicated network, add `storage_network` and a `storage_ip` per node. On a running cluster, this changes things that only apply at boot.

What happens on `apply`:

- **Proxmox hot-plugs the second NIC** and regenerates the cloud-init drive. The module never lets the provider reboot a node (`reboot_after_update = false`).
- **Talos reads the cloud-init network (nocloud) only at boot.** The new interface has no address until the node reboots.
- **Kernel modules** (`rbd`, `ceph`, `libceph`, added when Ceph CSI is enabled) **load live**, with no reboot.
- **etcd and the kubelet stay on the node network.** The module pins etcd's `advertisedSubnets` and the kubelet's `nodeIP` to `network.cidr`, so a second address never changes the cluster membership.

Procedure:

1. Add `storage_network` and the `storage_ip` values (Ceph CSI still disabled). Plan: the VMs and the Talos configuration change in place, and nothing is replaced. Apply.
2. Reboot the nodes **one at a time**: control-plane nodes first, the one holding the API VIP last, then the workers.

   ```shell
   talosctl -n <ip> reboot                      # waits until the node is back
   talosctl -n <ip> get addresses | grep <storage network prefix>
   talosctl -n <ip> etcd members                 # control-plane nodes: 3 members, unchanged peer URLs
   kubectl get nodes                             # all Ready before the next node
   ```

3. Check that every node reaches the storage network: Ceph monitors on TCP 3300 or 6789.
   Pods stopped by the graceful node shutdown stay listed as `Failed` ("terminated in response to imminent node shutdown"). Their replacements run elsewhere. Delete these records when you are done:
   `kubectl delete pods -A --field-selector=status.phase=Failed` (this deletes every Failed pod: check the list first).
4. Enable Ceph CSI and apply. Then `scripts/e2e-test.sh --all-storage-classes`.

## Destroying a cluster

1. **Uninstall Educates first** (`educates admin platform delete`, after deleting portals and workshops). Every volume is then deleted by its CSI driver while the cluster still runs. A volume still in use when the VMs are destroyed stays behind as an orphan disk in Proxmox, or an image or subvolume in Ceph.
2. Check that no volumes are left: `kubectl get pv` must be empty.
3. Destroy and review the plan before applying it:

   ```shell
   tofu plan -destroy -var-file=my-cluster.tfvars -out=destroy.out && tofu apply destroy.out
   scripts/jump-host.sh plan -destroy && scripts/jump-host.sh apply      # on a jump host
   ```

   It removes the VMs, the downloaded Talos image and the cluster resources. Deleting the image needs `Datastore.Allocate` on the image datastore (see requirements.md). Without it, the destroy stops at the image with HTTP 403: drop it from the state with `tofu state rm` and ask the Proxmox administrator to delete the file.
   Deleting many VMs at once on a Ceph RBD datastore can fail on Proxmox's side (`rbd: listing images failed`). Run the destroy again: the VMs that are already gone are skipped. An existing resource pool (`proxmox.pool`) is never touched; a pool created by the module (`create_pool`) is deleted.

## Notes

- **Discovery service.** Without the public Talos discovery service (air-gapped clusters, or disabled by policy), `talosctl get members` returns nothing. That is normal. Use `talosctl health` instead.
- **Controllers after a control-plane change.** After restarting or upgrading the control plane, check that controllers processed their resources, not only that their pods run. A controller that started before the API was reachable can switch a feature off without reporting it.
