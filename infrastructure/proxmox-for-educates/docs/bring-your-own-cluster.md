# Bring your own Talos cluster

For when you already run Talos Linux on Proxmox VE, or prefer to build the cluster yourself, and want to install Educates on it.

The modules in this repository build the cluster *and* the pieces Educates needs on top of it. This page lists those pieces, so you can add them to your own cluster by hand. Then check the result with the same end-to-end test, and install Educates as in [getting-started.md](getting-started.md#5-install-educates).

This page is written for Talos on Proxmox. Most of it also applies to other Kubernetes distributions on premises, especially with Cilium: LoadBalancer IPs, the workshop network policy, the end-to-end test. For Educates on other platforms, see the [Educates installation guides](https://github.com/educates/educates-training-platform/tree/develop/project-docs/installation-guides).

## Who does what

Two parties are usually involved:

- the **cluster owner**, who runs the Kubernetes cluster (and often Proxmox, DNS and the certificate authority);
- the **Educates installer**, who installs and operates Educates on it.

They can be the same team. The first check of a provided cluster goes in this order:

| Step | Who | What |
|---|---|---|
| 1 | Educates installer | Sends the cluster owner this page: what Educates needs (below), what it installs, and the images it pulls |
| 2 | Cluster owner | Runs [the cluster check](#check-the-cluster) with a `cluster-admin` kubeconfig, before anything is installed, and sends the output |
| 3 | Both | Go through every `FAIL` and `WARN`. Each one points to a section below: [Storage](#storage), [LoadBalancer IPs](#loadbalancer-ips), [Workshop network policy](#workshop-network-policy-cilium-only). The owner fixes them, by hand or through GitOps, and runs the check again until it passes |
| 4 | Cluster owner | Provides what the check cannot see: the domain and its wildcard DNS record, the ingress IP (one address of the LoadBalancer range), the wildcard certificate with its CA, and access for the Educates installer (a `cluster-admin` kubeconfig, a machine that reaches the API on TCP 6443 and the ingress IP on TCP 80 and 443) |
| 5 | Cluster owner | Without internet access from the cluster: mirrors the [images Educates pulls](#clusters-without-internet-access) |
| 6 | Educates installer | Installs Educates ([getting-started.md](getting-started.md#5-install-educates)), pins the ingress IP, and runs the check again with `--workshop`: a real workshop session over HTTPS |

## What Educates needs from the cluster

| Need | Why | Section |
|---|---|---|
| A default `ReadWriteOnce` StorageClass | Portal database, workshop volumes | [Storage](#storage) |
| `LoadBalancer` Services, with an IP you choose | The Educates ingress (Contour's Envoy), with the wildcard DNS record pointing to it | [LoadBalancer IPs](#loadbalancer-ips) |
| Workshop pods that reach cluster DNS and the API | With Cilium, the Educates workshop NetworkPolicy blocks them | [Workshop network policy](#workshop-network-policy-cilium-only) |
| Outbound access to container registries | Educates, its workshops (1.3 GB base image) | Your network |
| Pod Security | Talos enforces `baseline` by default | See [Pod Security](#pod-security) |

Educates 4 installs its own ingress controller (Contour), certificate handling and policy engine (Kyverno): do not install them yourself. See [What Educates installs](#what-educates-installs).

## Storage

One option is enough, with exactly one StorageClass marked as default (`storageclass.kubernetes.io/is-default-class: "true"`).

**Proxmox CSI** ([proxmox-csi-plugin](https://github.com/sergelogvinov/proxmox-csi-plugin)). Volumes are Proxmox disks attached to the VMs.

- A dedicated Proxmox token, with the privileges in [Credentials](requirements.md#credentials).
- The nodes must reach the Proxmox API (TCP 8006).
- Every node needs the labels `topology.kubernetes.io/region` (the region name in the plugin's configuration) and `topology.kubernetes.io/zone` (the Proxmox host it runs on). In Talos, set them with a `KubeNodeConfig` patch, or `machine.nodeLabels`.
- Install the chart `oci://ghcr.io/sergelogvinov/charts/proxmox-csi-plugin` (tested: 0.5.15) in a namespace labelled `pod-security.kubernetes.io/enforce: privileged`, with a StorageClass per datastore:

```yaml
# values.yaml (keep the token secret out of git; the module stores it in a Secret instead)
config:
  clusters:
  - url: https://pve.example.com:8006/api2/json   # an address the nodes reach
    insecure: true                               # self-signed Proxmox certificate
    token_id: "kubernetes-csi@pve!csi"
    token_secret: "<secret>"
    region: pve                                  # = the nodes' topology.kubernetes.io/region label
storageClass:
- name: proxmox-local
  storage: local-lvm                             # the Proxmox datastore for volumes
  fstype: ext4
  ssd: true
  reclaimPolicy: Delete
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

```shell
kubectl create namespace csi-proxmox
kubectl label namespace csi-proxmox pod-security.kubernetes.io/enforce=privileged
helm install proxmox-csi-plugin oci://ghcr.io/sergelogvinov/charts/proxmox-csi-plugin --version 0.5.15 \
  --namespace csi-proxmox -f values.yaml
```

**Ceph CSI** ([ceph-csi](https://github.com/ceph/ceph-csi)), with an existing Ceph cluster: RBD for RWO volumes, CephFS for RWX ones.

- The nodes must reach the Ceph monitors and OSDs.
- Load the `rbd`, `ceph` and `libceph` kernel modules with a Talos `KernelModuleConfig` per module. They load live, with no reboot.
- **ceph-csi 3.18 and later need x86-64-v3 CPUs (AVX2)**: on older CPUs, or the `x86-64-v2-AES` VM CPU type, use 3.17.x.
- The Ceph clients need the capabilities in the [module README](../README.md#ceph-csi).
- Install the `ceph-csi-rbd` and `ceph-csi-cephfs` charts in two separate privileged namespaces: they share ConfigMap names.

With Ceph, make RBD the default class: Proxmox CSI is limited to about 30 disks per VM, and Educates creates many small volumes.

## LoadBalancer IPs

With Cilium, enable L2 announcements in its Helm values, on top of the Talos defaults (kubeProxyReplacement, KubePrism):

```yaml
l2announcements:
  enabled: true
k8sClientRateLimit:     # L2 announcements use leases: raise the API rate limits
  qps: 50
  burst: 100
```

Then apply a pool of free IPs in the node network and an announcement policy (`kubectl apply -f`):

```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  blocks:
  - start: 192.168.10.240
    stop: 192.168.10.249
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default
spec:
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
```

Another implementation (MetalLB, kube-vip) works too. Pinning the ingress IP then uses that implementation's own annotation instead of `lbipam.cilium.io/ips`.

## Workshop network policy (Cilium only)

Educates puts a NetworkPolicy in every workshop namespace that allows all egress except the cloud metadata IP, written as an `ipBlock`. Cilium applies `ipBlock` only to traffic leaving the cluster. So, without the policy below, workshop pods cannot reach cluster DNS, Services or the API, and sessions fail to start or to log in. Cilium policies add up: this one restores in-cluster egress for Educates workshop namespaces only.

```yaml
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: educates-allow-in-cluster
spec:
  endpointSelector:
    matchExpressions:
    - key: io.cilium.k8s.namespace.labels.training.educates.dev/component
      operator: In
      values: [environment, session]
  egress:
  - toEntities: [cluster, kube-apiserver]
  - toCIDRSet:                          # the Educates rule, so the policy means the same on its own
    - cidr: 0.0.0.0/0
      except: [169.254.169.254/32]
```

With another CNI (for example Calico, which matches pod IPs with `ipBlock`), this is not needed.

## What Educates installs

Tested with Educates `4.0.0-alpha.13` in `Managed` mode, the mode in [getting-started.md](getting-started.md#5-install-educates):

- **The Educates installer:** a Helm chart in namespace `educates-installer`. It runs the Educates operator, adds the CRDs of `config.educates.dev` and `platform.educates.dev`, and creates the ClusterRoles `educates:installer:*` and `educates:rbac:*`. The operator runs with a fine-grained ClusterRole generated from the charts it installs, not `cluster-admin`. The chart value `rbac.clusterAdmin` binds it to `cluster-admin` instead, as a fallback.
- **The platform**, installed by the operator: the secrets manager, session manager, lookup service, node CA injector (a DaemonSet) and remote access. Their CRDs are in `secrets.educates.dev` and `training.educates.dev`.
- **Cluster services**, from charts bundled with the operator: Contour (with an Envoy `LoadBalancer` Service), Kyverno (cluster-wide admission webhooks and policies), and, when the configuration uses them, cert-manager and external-dns.
- **At run time**, the session manager creates namespaces, Roles, RoleBindings, ResourceQuotas and LimitRanges for every workshop environment and session.

Installing it needs `cluster-admin`. In `Inline` mode (`EducatesInlineConfig`), the operator uses an ingress controller, a wildcard certificate and a policy engine that already exist, and installs nothing at cluster scope. That mode is not tested here.

To review everything before installing, render it: `educates admin platform render --config educates.yaml`.

## Clusters without internet access

Each Educates release publishes the list of images it uses: `educates-images-<version>.txt` in its [GitHub release](https://github.com/educates/educates-training-platform/releases). For `4.0.0-alpha.13`, 42 images from these registries:

| Registry | Images |
|---|---|
| `ghcr.io` | Educates (`ghcr.io/educates/*`), Contour, Kyverno readiness checker, vcluster |
| `reg.kyverno.io` | Kyverno |
| `quay.io` | cert-manager |
| `docker.io` | Envoy, `docker:*-dind`, `debian` (short names resolve to `docker.io`) |
| `registry.k8s.io` | external-dns |

On Talos, the simplest way is a pull-through cache (for example Harbor) per registry and a registry mirror in the machine configuration (`machine.registries.mirrors`). Image names do not change, so nothing in Educates needs configuring. Two things stay outside the mirrors:

- **Workshop images and content.** Each workshop has its own images, and many download their files when the session starts (for example from GitHub or `ghcr.io`), from inside the session pod. Check each workshop you plan to run.
- **The cluster check** pulls `registry.k8s.io/e2e-test-images/agnhost`, and with `--workshop` a sample workshop from GitHub.

## Pod Security

Educates' own recommendation is to enforce security with Kyverno, not with Pod Security Standards, and that is the configuration tested here (`policyEnforcement.clusterPolicy.engine: Kyverno`). Educates then sets no `pod-security.kubernetes.io/enforce` label on workshop namespaces: its Kyverno policies apply the security policy of each workshop. Educates 4, its system components and workshop sessions ran on Talos's default (`baseline` enforced) in these tests.

Not tested: workshops that need privileged pods, such as Docker in the session. With `baseline` enforced cluster-wide, their namespaces may need the `privileged` level. Also not tested: `pod-security-standards` as the policy engine, where Educates labels the namespaces itself: training portals `baseline`, workshop environments `privileged`, and session namespaces with the workshop's policy (`restricted` by default).

## Check the cluster

`scripts/e2e-test.sh` works with any Kubernetes cluster, not only one built by these modules. Run it from a machine with `kubectl`, `curl` and `jq` that reaches the Kubernetes API and the LoadBalancer range, with a `cluster-admin` kubeconfig. It creates, and deletes at the end, a few test namespaces, a volume per StorageClass, a `LoadBalancer` Service (it holds one IP of the range for a minute) and some pods. It runs the Talos health check only on Talos nodes with `TALOSCONFIG` set, and skips it otherwise. Point it at your kubeconfig:

```shell
git clone https://github.com/educates/educates-terraform-modules.git
cd educates-terraform-modules/root-modules/educates-on-proxmox
export KUBECONFIG=<your kubeconfig>       # and TALOSCONFIG, for the Talos health check
scripts/e2e-test.sh                       # storage, LoadBalancer, pod network, the workshop network policy
```

Every check should pass:

- **storage:** a volume is created, written and deleted;
- **LoadBalancer:** a Service gets an IP and answers;
- **workshop network:** a replica of the Educates workshop namespace and its policy reaches cluster DNS, Services and the API.

Then [install Educates](getting-started.md#5-install-educates), and run `scripts/e2e-test.sh --workshop` for a real workshop session.
