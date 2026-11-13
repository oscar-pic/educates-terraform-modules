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
3. Run `tofu apply`, so the code matches what runs. This replaces the downloaded Talos image and updates the installer image in the machine configuration. It must **not** replace any VM: if the plan shows a VM being replaced, stop.

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
- **Removing a worker.** Drain it first, then remove it from `nodes`.
- **Removing a control-plane node.** Remove it from etcd first (`talosctl -n <node-ip> reset --graceful`), and keep an odd number of control-plane nodes.
