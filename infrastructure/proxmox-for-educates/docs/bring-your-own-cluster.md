# Bring your own Talos cluster

For when you already run Talos Linux on Proxmox VE, or prefer to build the cluster yourself, and want to install Educates on it.

The modules in this repository build the cluster *and* the pieces Educates needs on top of it. This page lists those pieces, so you can add them to your own cluster by hand. Then check the result with the same end-to-end test, and install Educates as in [getting-started.md](getting-started.md#5-install-educates).

This page is written for Talos on Proxmox. Most of it also applies to other Kubernetes distributions on premises, especially with Cilium: LoadBalancer IPs, the workshop network policy, the end-to-end test. For Educates on other platforms, see the [Educates installation guides](https://github.com/educates/educates-training-platform/tree/develop/project-docs/installation-guides).

## What Educates needs from the cluster

| Need | Why | Section |
|---|---|---|
| A default `ReadWriteOnce` StorageClass | Portal database, workshop volumes | [Storage](#storage) |
| `LoadBalancer` Services, with an IP you choose | The Educates ingress (Contour's Envoy), with the wildcard DNS record pointing to it | [LoadBalancer IPs](#loadbalancer-ips) |
| Workshop pods that reach cluster DNS and the API | With Cilium, the Educates workshop NetworkPolicy blocks them | [Workshop network policy](#workshop-network-policy-cilium-only) |
| Outbound access to container registries | Educates, its workshops (1.3 GB base image) | Your network |
| Pod Security | Talos defaults to `baseline`; Educates labels its own namespaces `privileged` | Nothing to do |

Educates 4 installs its own ingress controller (Contour), certificate handling and policy engine (Kyverno): do not install them yourself.

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

## Check the cluster

`scripts/e2e-test.sh` works with any Kubernetes cluster, not only one built by these modules. It runs the Talos health check only on Talos nodes with `TALOSCONFIG` set, and skips it otherwise. Point it at your kubeconfig:

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
