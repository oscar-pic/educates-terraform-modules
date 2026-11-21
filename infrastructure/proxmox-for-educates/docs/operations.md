# Day-2 operations

Operating a cluster built with these modules, and Educates on it.

Where this page says `tofu plan` or `tofu apply`, use the same form as for the deployment: `tofu plan -var-file=my-cluster.tfvars -out=my-cluster.tfplan`, then `tofu apply my-cluster.tfplan`. On a jump host, `scripts/jump-host.sh plan` and `scripts/jump-host.sh apply`, which also pass `client_configs_dir`.

- [Using kubectl and talosctl](#using-kubectl-and-talosctl)
- [Changing the configuration](#changing-the-configuration)
- [Upgrading Kubernetes](#upgrading-kubernetes) and [Talos](#upgrading-talos)
- [Updating Cilium or the Gateway API CRDs](#updating-cilium-or-the-gateway-api-crds)
- [Draining a node](#draining-a-node-by-hand), [scaling](#scaling), [adding a storage network](#adding-a-storage-network-to-a-running-cluster)
- [Renewing the Educates certificate](#renewing-the-educates-certificate)
- [Uninstalling Educates](#uninstalling-educates) and [destroying the cluster](#destroying-a-cluster)

Rehearse every procedure on a test cluster first.

## Using kubectl and talosctl

The deployment writes `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>` to `client_configs_dir`: next to the root module, or to `<work dir>/state` on a jump host. Keep them as separate files, like the kubeconfig files of the EKS and GKE modules: never merge them into `~/.kube/config` or `~/.talos/config`. Point the tools at them:

```shell
export KUBECONFIG=<dir>/kubeconfig-<cluster_name>.yaml
export TALOSCONFIG=<dir>/talosconfig-<cluster_name>

kubectl get nodes -o wide
talosctl health                            # checks the whole cluster
talosctl -n <node-ip> dashboard            # live view of one node
talosctl -n <node-ip> logs kubelet
```

Without `-n`, `talosctl` talks to the first control-plane node.

On a jump host, `scripts/jump-host.sh shell` opens a `tmux` session with all of this set. To work in an SSH session of your own instead, load the same environment first:

```shell
. <work dir>/repo/root-modules/educates-on-proxmox/scripts/guest-env.sh <work dir>
```

It keeps every tool inside the work directory, so nothing is written to the jump host user's home.

## Changing the configuration

Edit the variables and run `tofu apply`. `talos_machine` re-applies the new machine configuration to each node, and Talos decides whether a reboot is needed.

- **Reboots.** Some changes need one. For example, etcd extra arguments only take effect after a reboot.
- **API server restarts.** Changing the API server authentication configuration restarts the API server on each control-plane node for about 10 s.
- **Several control-plane nodes.** `talos_machine` sends a changed configuration to every node in parallel, and Talos applies it in its automatic mode: live when it can, with a reboot when it must. The provider has no setting to stage it instead. A change that reboots all control-plane nodes at once loses etcd quorum until they are back. So, before applying a change to every node, check whether it needs a reboot (most do not: patches, kernel modules, labels, certificates). For one that does, apply with `-parallelism=1` and watch each node come back, or stage it per node with `talosctl apply-config --mode staged` and reboot one at a time.
- **VM settings.** The provider never reboots a VM (`reboot_after_update = false`). A VM change that needs the VM offline makes the apply fail: stop or reboot that VM by hand, one at a time, and apply again. A change that is applied live but needs a reboot gives a warning.
- **Talos merges lists by appending.** To replace a list entry, delete the document in one patch and add it back in another. The module does this for the default `KubeNodeConfig`.
- **Do not change `talos.config_contract`.** It regenerates every node's configuration and may rotate secrets.

## Upgrading Kubernetes

1. Set `talos.kubernetes_version` to the new version.
2. Run `tofu apply`.

`talos_cluster` then runs Talos's `upgrade-k8s`: it upgrades the API server, controller manager and scheduler, then the kubelet node by node, with health checks between steps. No node reboots.

What to expect, measured on a 3 + 3 node cluster going from 1.36.6 to 1.37.2:

- **Duration.** About 9 minutes.
- **The node configurations.** The plan also shows every `talos_machine` changing. That only updates the state: with `ignore_kubernetes_upgrade_drift`, the provider does not push the new Kubernetes images to the nodes, so `upgrade-k8s` alone upgrades them, in order.
- **An API outage of about 40 seconds through the VIP.** It happens when the API server of the node holding the VIP restarts. The VIP stays on its node while the node is alive: it is a floating IP, not a load balancer. External clients (`kubectl`, CI) see this gap. Workloads inside the cluster do not: they reach the API through KubePrism, which balances across the API servers. Educates kept answering during the whole upgrade.

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

What to expect, measured on a 3 + 3 node cluster going from v1.14.5 to v1.14.6:

- **About 2 minutes per node.**
- **No API outage.** Talos moves the VIP before it shuts the node down.
- **The final `tofu apply` replaces only the downloaded image.** It also updates the installer in the configurations, live and with no reboot, and the next plan shows no changes.
- **Workloads with a single replica and a `ReadWriteOnce` volume are unavailable while their node is upgraded.** Their pod moves to another node only after the volume is detached from the old one. The Educates training portal is one of them: it was unreachable for about 2 minutes, then came back with its data. Upgrade workers outside class hours.

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

### Shutting a node down with Proxmox HA

With `proxmox.ha_enabled`, every VM is an HA resource in state `started`: Proxmox starts again any VM that stops. **`talosctl shutdown` then works as a reboot.** Tested on a worker: Proxmox started the VM again about 30 seconds after the shutdown, and the node was `Ready` (and uncordoned by Talos) about 90 seconds after that. Reboots and Talos upgrades are not affected.

To keep a node down, for example for maintenance of its host, stop it through HA instead. Drain it first, as above:

```shell
ha-manager set vm:<vm-id> --state stopped     # on a Proxmox host, or Datacenter > HA in the web UI
ha-manager set vm:<vm-id> --state started     # to start it again
```

A manual migration (`ha-manager migrate vm:<vm-id> <host>`) is temporary: failback, or the next apply, brings the VM back to its `proxmox_node`. To move a VM for good, change its `proxmox_node` and apply. For host maintenance, stop the VM as above, or use the host's HA maintenance mode. The token of the module does not need these privileges: they are for the Proxmox administrator.


### When a Proxmox host fails

Tested by powering off one of three hosts from its BMC, with a control-plane node, a worker, the training portal and a workshop session on it, and Proxmox HA on:

| After the power-off | What happened |
|---|---|
| ~20 s | The API, through the VIP, failed for about 15 s while the VIP moved. etcd kept quorum (2 of 3) |
| ~1.5 min | Kubernetes marked both nodes `NotReady`. The portal and the session were down |
| ~3 min | Proxmox HA fenced the host and started both VMs on the other hosts (shared Ceph storage) |
| ~6 min | Both nodes `Ready`. Kubernetes had evicted their pods after 5 minutes: the session restarted on another worker, with its volume |
| — | **The training portal did not come back by itself.** See below |

**When the host comes back.** Each VM has an HA rule that prefers its `proxmox_node`, and failback is on: Proxmox migrates the VMs back to their host by itself, live. Tested: both VMs were back about 1.5 minutes after the host rejoined, with no API or portal outage. Until then:

- Do not apply. A VM on another host than its `proxmox_node` is migrated back by the next apply (`migrate = true`), and if its host is still down, the apply fails. It is never destroyed and created again. A `-target` on the HA resources or rules includes the VMs too, since they depend on them.
- Proxmox CSI volumes of a moved VM may fail to attach: the node's `topology.kubernetes.io/zone` label still names its own host.

Without Proxmox HA, the cluster behaves the same until the VMs come back with their host. Kubernetes still moves the pods after 5 minutes.

**The training portal after a node failure.** Educates 4 bundles Kyverno with one replica, and its webhooks block pod creation while Kyverno is down. If Kyverno ran on the failed node, the portal's replacement pod is rejected. Kubernetes then waits longer and longer between retries. When Kyverno is back, restart the portal:

```shell
kubectl -n kyverno get pods                                              # Running again
kubectl -n <portal>-ui rollout restart deployment/training-portal       # for example educates-cli-ui
```

The same applies to any pod Educates creates while Kyverno is down, for example new workshop sessions. Reported to the Educates team ([educates-feedback.md](educates-feedback.md), item 14).

## Scaling

- **Adding a node.** Add it to `nodes` and apply. It joins at `talos.kubernetes_version`.
- **Going from one to three control-plane nodes.** Add two `controlplane` nodes, preferably on different Proxmox hosts, and apply. The new nodes join etcd, and the existing nodes are not changed or rebooted. This needs `network.api_vip` set **from the start**: the cluster endpoint is fixed when the cluster is created. Without a VIP it is the first node's IP, and growing then means rebuilding the cluster. If a single-node cluster may grow, give it a VIP anyway.
- **Checking control-plane failover.** Reboot the node that holds the VIP (`talosctl -n <ip> get addresses` shows it) while polling `https://<vip>:6443/version`. Any HTTP answer, including 401, means the API is up. The VIP moves to another control-plane node, and the API keeps answering.
- **Removing a worker.** Drain it first, then remove it from `nodes`.
- **Removing a control-plane node.** Remove it from etcd first (`talosctl -n <node-ip> reset --graceful`), and keep an odd number of control-plane nodes.
- **The bootstrap node.** The first control-plane key in alphabetical order bootstrapped etcd. The module never bootstraps again, even if that key is removed or a new key sorts first. But the Kubernetes upgrades (`upgrade-k8s`) still go through that node, so keep it, or keep its key's IP pointing to a control-plane node.

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

## Renewing the Educates certificate

`StaticCertificate` renews nothing. When the certificate is renewed (by your CA's tooling, or by you), update your Secret, `educates-static-tls`. The operator keeps its own copy (`educates-wildcard-tls`) in step with it, and Educates passes it on to the namespaces that use it, with no redeploy. So a tool that keeps the Secret up to date, such as External Secrets reading from a vault, renews the certificate with no work in Educates:

```shell
kubectl -n educates-installer create secret tls educates-static-tls --cert=tls.crt --key=tls.key \
  --dry-run=client -o yaml | kubectl apply -f -
# A minute or two later, check what the ingress serves:
echo | openssl s_client -connect <any-host>.<domain>:443 -servername <any-host>.<domain> 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

Do the same with `educates-static-ca` if the root CA changes. The certificate's `notAfter` date tells you when to renew.

## Uninstalling Educates

Do it before destroying the cluster. Every volume is then deleted by its CSI driver while the cluster still runs. Volumes left behind become orphan disks in Proxmox, or images and subvolumes in Ceph.

```shell
# 1. Portals: their workshops, sessions and the portal's own volume go with them.
kubectl delete trainingportals --all --wait=true
# 2. Give Educates a few minutes to clean up what it copied for the portals (some may remain).
kubectl get secretcopiers.secrets.educates.dev
# 3. The platform: operator, Contour, Kyverno, and with --purge its CRDs and namespaces.
educates admin platform delete --yes --purge
# 4. What Educates 4 leaves behind: the "educates" namespace and the runtime CRDs.
kubectl delete namespace educates --ignore-not-found
kubectl get crd -o name | grep -E '\.educates\.dev$' | xargs -r kubectl delete
#    If that hangs, SecretCopiers are stuck with a finalizer nobody removes any more:
#    kubectl get secretcopiers.secrets.educates.dev -o name | \
#      xargs -r -I{} kubectl patch {} --type=merge -p '{"metadata":{"finalizers":null}}'
#    Kyverno may leave behind webhooks it created itself (failurePolicy Fail, pointing to a
#    Service that no longer exists). Delete them:
kubectl delete validatingwebhookconfigurations,mutatingwebhookconfigurations -l webhook.kyverno.io/managed-by=kyverno
# 5. Check: no volumes left, and nothing of Educates, Contour or Kyverno (no output).
kubectl get pv
kubectl get namespaces,crd,apiservices,validatingwebhookconfigurations,mutatingwebhookconfigurations,ingressclasses,clusterroles,clusterrolebindings \
  -o name | grep -E 'educates|kyverno|contour|wgpolicyk8s'
```

On a cluster you did not build, the last command may also list objects of the cluster owner's that only carry the name, such as the binding that gave you access: check before deleting anything it shows.

## Destroying a cluster

1. **Uninstall Educates first** ([above](#uninstalling-educates)). Every volume is then deleted by its CSI driver while the cluster still runs. A volume still in use when the VMs are destroyed stays behind as an orphan disk in Proxmox, or an image or subvolume in Ceph.
2. Check that no volumes are left: `kubectl get pv` must be empty.
3. Destroy and review the plan before applying it:

   ```shell
   tofu plan -destroy -var-file=my-cluster.tfvars -out=destroy.tfplan && tofu apply destroy.tfplan && rm destroy.tfplan
   scripts/jump-host.sh plan -destroy && scripts/jump-host.sh apply      # on a jump host
   ```

   It removes the VMs, the downloaded Talos image and the cluster resources. Deleting the image needs `Datastore.Allocate` on the image datastore (see requirements.md). Without it, the destroy stops at the image with HTTP 403: drop it from the state with `tofu state rm` and ask the Proxmox administrator to delete the file.
   Deleting many VMs at once on a Ceph RBD datastore can fail on Proxmox's side (`rbd: listing images failed`). Run the destroy again: the VMs that are already gone are skipped. An existing resource pool (`proxmox.pool`) is never touched; a pool created by the module (`create_pool`) is deleted.

## Notes

- **Discovery service.** Without the public Talos discovery service (air-gapped clusters, or disabled by policy), `talosctl get members` returns nothing. That is normal. Use `talosctl health` instead.
- **Controllers after a control-plane change.** After restarting or upgrading the control plane, check that controllers processed their resources, not only that their pods run. A controller that started before the API was reachable can switch a feature off without reporting it.
