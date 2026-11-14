# Getting started: Educates on your Proxmox VE

This guide takes you from an existing Proxmox VE to a running Educates. Each step links to the reference that has the details.

1. Prepare Proxmox: datastores, network, API tokens.
2. Choose the machine you deploy from: your workstation or a jump host.
3. Fill in the files for your site.
4. Check the requirements, then deploy the cluster.
5. Install Educates.

These modules build the layer below Educates: a Talos Linux Kubernetes cluster with Cilium, LoadBalancer IPs and storage. Educates itself is installed afterwards with its own installer.

## 1. Prepare Proxmox

Usually done by the Proxmox administrator. Full list: [requirements.md](requirements.md).

- **Proxmox VE 8.4 or later.**
- **Datastores:**
  - one for the Talos image, with the `Import` content type enabled (Datacenter → Storage → *datastore* → Content). A shared one (CephFS, NFS) downloads the image only once.
  - one for VM disks. It must be shared if you want Proxmox HA.
- **Network:**
  - a bridge or SDN VNet for the nodes;
  - one free IP per node;
  - one IP for the Kubernetes API VIP (with several control-plane nodes);
  - a range of 5–10 free IPs for LoadBalancer Services.

  All of them in the same layer-2 network. On a VXLAN or EVPN VNet, plan `network.mtu = 1`.
- **Outbound access, or mirrors:**
  - from the Proxmox hosts to `factory.talos.dev`;
  - from the nodes to the container registries, DNS and NTP;
  - with Proxmox CSI, from the nodes to the Proxmox API (TCP 8006), with the return route.
- **Two API tokens**, with minimal privileges: one for OpenTofu, one for Proxmox CSI. See [Credentials](requirements.md#credentials) for the table and the `pveum` commands.
- **For Educates:**
  - a domain, and a wildcard DNS record `*.<domain>` pointing to one IP of the LoadBalancer range (you get the exact IP in step 5);
  - a way to get certificates for that domain (see step 5).

Size the nodes with [Sizing](requirements.md#sizing). Educates suggests starting with three workers of 16–32 GB.

## 2. Choose where you deploy from

The machine that runs OpenTofu must reach the Proxmox API and every node on TCP 50000 (Talos) and 6443 (Kubernetes).

| | A. Your workstation | B. A jump host |
|---|---|---|
| Use it when | It reaches the node network directly: same network, or a VPN that routes the whole node subnet | Anything else |
| How | Run the commands in your clone | Drive the jump host over SSH with `scripts/jump-host.sh` |

Tools, on that machine: OpenTofu ≥ 1.6 (or Terraform ≥ 1.6), `kubectl`, `talosctl` (same minor version as Talos), `jq`, `curl`, `git`. For a jump host, also `tmux`. For step 5, the [Educates CLI](https://github.com/educates/educates-training-platform/releases) or `helm`.

Details: [Where you deploy from](requirements.md#where-you-deploy-from-workstation-or-jump-host).

## 3. Fill in your files

Get the code. Fork or clone this repository; the deploying machine only needs read access to it:

```shell
git clone https://github.com/educates/educates-terraform-modules.git
cd educates-terraform-modules/root-modules/educates-on-proxmox
```

Your site's values never go into the repository. Start from the templates in [root-modules/educates-on-proxmox](../../../root-modules/educates-on-proxmox/):

| Template | You fill in | Keep it |
|---|---|---|
| `examples/single-host.tfvars.example` (one host, one node) or `examples/ha.tfvars.example` (three hosts, HA) | Proxmox URL, datastores, network, nodes (IP, Proxmox host, VM ID, size), LoadBalancer range, storage | As `<name>.tfvars` (git-ignored), or outside the clone |
| `proxmox.env.example` | The two token secrets (and the Ceph key, if used) | Outside the clone, mode 0600 |
| `backend_override.tf.example` | Optional: where the state lives | As `backend_override.tf` (git-ignored) |
| `jump-host.env.example` | Option B only: SSH name of the jump host, work directory, tfvars file name | As `jump-host.env` (git-ignored) |

The variables are documented in [variables.tf](../variables.tf) and in the comments of the examples.

## 4. Check, then deploy the cluster

### Option A: from your workstation

```shell
cd root-modules/educates-on-proxmox
set -a; . ~/educates/proxmox.env; set +a     # secrets into this shell only

tofu init
scripts/preflight.sh --var-file my-cluster.tfvars    # tools, Proxmox API, token privileges, datastores, network
tofu plan  -var-file=my-cluster.tfvars -out=plan.out
tofu apply plan.out                                   # 10–20 minutes
scripts/preflight.sh --var-file my-cluster.tfvars --after
```

### Option B: from a jump host

On your workstation, with `jump-host.env` filled in:

```shell
cd root-modules/educates-on-proxmox
scripts/jump-host.sh setup       # work directory, clone at your pushed commit, state outside the clone
```

On the jump host, put your `.tfvars` and `proxmox.env` in the work directory. Then, from your workstation:

```shell
scripts/jump-host.sh preflight   # the checks, run on the jump host
scripts/jump-host.sh plan        # review what will be created
scripts/jump-host.sh apply       # runs inside tmux; run it again to re-attach
scripts/jump-host.sh preflight --after
scripts/jump-host.sh shell       # shell with KUBECONFIG and TALOSCONFIG set
```

### What you get

- VMs named `<cluster_name>-<node>`, running Talos Linux.
- Kubernetes with Cilium.
- A LoadBalancer IP pool.
- The storage driver you chose, with a default StorageClass.
- `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>`, written next to the root module or to `client_configs_dir`. They are admin credentials: keep them private.

### Using kubectl and talosctl

The deployment writes two client files, `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>`, to `client_configs_dir`: next to the root module, or `<work dir>/state` on a jump host. They are **separate files**, like the kubeconfig files of the EKS and GKE modules. Never merge them into `~/.kube/config` or `~/.talos/config`, least of all on a shared jump host where those files belong to someone else. Point the tools at them instead, in one of three ways.

**1. Environment variables**, for a whole shell session:

```shell
export KUBECONFIG=<dir>/kubeconfig-<cluster_name>.yaml
export TALOSCONFIG=<dir>/talosconfig-<cluster_name>

kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
talosctl health                            # endpoints and nodes come from the talosconfig
talosctl -n <node-ip> dashboard            # live view of one node
talosctl -n <node-ip> logs kubelet
```

**2. Explicit flags**, for a single command, without touching the environment:

```shell
kubectl --kubeconfig <dir>/kubeconfig-<cluster_name>.yaml get nodes
talosctl --talosconfig <dir>/talosconfig-<cluster_name> -n <node-ip> version
```

**3. On a jump host, the prepared session.** From your workstation:

```shell
scripts/jump-host.sh shell
```

It opens a `tmux` session on the jump host, in the root module directory. `KUBECONFIG`, `TALOSCONFIG`, the secrets and `<work dir>/bin` are already set, and `HOME` points inside the work directory. To work in an SSH session of your own instead, load the same environment first:

```shell
ssh <jump host>
. <work dir>/repo/root-modules/educates-on-proxmox/scripts/guest-env.sh <work dir>
kubectl get nodes
```

Load it before running `kubectl`, `helm`, `talosctl` or `tofu` on a jump host that is not yours. Without it, those tools write caches to the host user's home (`~/.kube/cache`, `~/.kube/http-cache`, `~/.cache/helm`).

Without `-n`, `talosctl` talks to the talosconfig's default node, the first control-plane node (`talosctl config info` shows it). `talosctl health` checks the whole cluster from there. For other nodes, pass `-n <ip>`, or several at once: `-n <ip1>,<ip2>`.

## 5. Install Educates

Educates 4 is installed by an operator, with the Educates CLI or with Helm. The official guides are in the [Educates installation guides](https://github.com/educates/educates-training-platform/tree/develop/project-docs/installation-guides). Read them first, especially:

- the cluster requirements;
- the CLI-based and Helm-based installations;
- the configuration settings;
- secure HTTP connections.

The cluster built here meets what Educates expects:

| Educates needs | This cluster provides |
|---|---|
| An ingress on ports 80/443 | Educates installs Contour (`BundledContour`). Its Envoy Service gets an IP from your LoadBalancer range |
| A default `ReadWriteOnce` StorageClass | Your `storage.default_class` |
| Pod Security levels for its namespaces | Talos defaults to `baseline`; the Educates operator labels its own namespaces `privileged` |
| A policy engine | Educates installs Kyverno (`kyverno.provider: Bundled`) |

A generic Kubernetes cluster has no dedicated configuration kind, so use `EducatesConfig` in `Managed` mode. This example uses a lab CA, which is the simplest option for a private domain; your users' browsers must trust that CA.

```yaml
# educates.yaml
apiVersion: cli.educates.dev/v1alpha1
kind: EducatesConfig
educatesClusterConfig:
  mode: Managed
  ingress:
    domain: workshops.example.com           # your domain; *.workshops.example.com -> Envoy IP
    ingressClassName: contour
    controller:
      provider: BundledContour
      bundledContour:
        envoyServiceType: LoadBalancer      # takes an IP from the Cilium LoadBalancer pool
    certificates:
      provider: BundledCertManager
      bundledCertManager:
        issuerType: CustomCA
        customCA:
          caKeyPairSecretRef:
            name: educates-custom-ca
  policyEnforcement:
    clusterPolicy:
      engine: Kyverno
    workshopPolicy:
      engine: Kyverno
    kyverno:
      provider: Bundled
secretsManager: {}
sessionManager: {}
```

```shell
export KUBECONFIG=$PWD/kubeconfig-<cluster_name>.yaml

# The lab CA (tls.crt/tls.key of a CA certificate), in the operator namespace, before deploying.
kubectl create namespace educates-installer
kubectl -n educates-installer create secret tls educates-custom-ca --cert=ca.crt --key=ca.key

educates admin platform render --config educates.yaml    # optional: review what will be applied
educates admin platform deploy --config educates.yaml

# The EXTERNAL-IP of the Envoy LoadBalancer Service: point *.<domain> to it.
kubectl -n contour get services
```

Other certificate options:

- **Your own wildcard certificate:** `StaticCertificate`.
- **Let's Encrypt with DNS-01:** `BundledCertManager` with ACME. Only the DNS providers that Educates supports.

Both are described in the Educates guides. Without the Educates CLI, install the `educates-installer` Helm chart and apply the four custom resources with `kubectl`, as the Helm-based installation guide explains.

Then deploy a workshop and open the training portal, following the Educates documentation.

> Educates 4 is in alpha, and its configuration may change between releases: check the guides of the version you install. Gateway API support (with agentgateway) is coming to Educates. This cluster can install the Gateway API CRDs already (`gateway_api.enabled`).

## Next

- Day-2 operations: [upgrades.md](upgrades.md). Talos upgrades are done one node at a time with `talosctl`; Kubernetes upgrades by changing `talos.kubernetes_version`.
- Design and open points: [redesign.md](redesign.md).
- Removing everything: uninstall Educates first (`educates admin platform delete`), then `tofu destroy` with the same tfvars file.
