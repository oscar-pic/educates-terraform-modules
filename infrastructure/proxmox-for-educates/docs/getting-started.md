# Getting started: Educates on your Proxmox VE

This guide takes you from an existing Proxmox VE to a running Educates, one step after another. Follow it in order. It links to the reference documents only for details.

1. [Prepare Proxmox](#1-prepare-proxmox), with your Proxmox administrator.
2. [Prepare the machine you deploy from](#2-prepare-the-machine-you-deploy-from): your workstation or a jump host.
3. [Get the code and fill in your files](#3-get-the-code-and-fill-in-your-files).
4. [Deploy the cluster](#4-deploy-the-cluster).
5. [Install Educates](#5-install-educates).

Already have a Talos cluster? See [Bring your own Talos cluster](bring-your-own-cluster.md).

## What you are building

- **Talos Linux VMs on Proxmox.** Talos is an operating system made only to run Kubernetes:
  - it has no SSH and no shell, and its disks are read-only;
  - you manage it with `talosctl`, through the Talos API on TCP 50000;
  - its configuration is a YAML document that these modules write for you.
- **A Kubernetes cluster on those VMs:**
  - one node for an evaluation, or three control-plane nodes plus workers;
  - Cilium for the network;
  - LoadBalancer IPs from your network;
  - volumes from Proxmox (Proxmox CSI) or Ceph (Ceph CSI).
- **Educates on top**, installed with its own installer (Educates 4).

OpenTofu (or Terraform) builds everything up to the cluster in one `apply`, through the Proxmox API only: nothing is installed on your Proxmox hosts. Unknown terms: see the [glossary](#glossary).

## 1. Prepare Proxmox

Do this with your Proxmox administrator. The [requirements](requirements.md) have the details and a checklist. You need:

- **Proxmox VE 8.4 or later.**
- **Two datastores:**
  - one for the Talos image, with the `Import` content type enabled (Datacenter → Storage → *datastore* → Content), for example `local`;
  - one for VM disks, for example `local-lvm`.
- **A resource pool** for the cluster's VMs (`pveum pool add educates`), and a **range of VM IDs** for them.
- **Two API tokens**, one for OpenTofu and one for Proxmox CSI, with the [privileges in Credentials](requirements.md#credentials): on the pool, the datastores, the node that downloads the image and the bridge.
- **Network:**
  - a bridge (for example `vmbr0`), and one free IP per node;
  - with more than one control-plane node, one IP for the Kubernetes API (the VIP);
  - a **range of 5–10 free IPs for LoadBalancer Services**.

  All of them in the node network, outside any DHCP range.
- **DNS and NTP servers** the nodes can use. The DNS must resolve the Proxmox host name in your Proxmox URL: the cluster's storage driver calls the Proxmox API by that name. Set them in your tfvars (`network.dns_servers`, `talos.ntp_servers`): the defaults are public servers.
- **Outbound access** (or mirrors):
  - from the Proxmox hosts to `factory.talos.dev`;
  - from the nodes to container registries, DNS and NTP;
  - from the nodes to the Proxmox API (TCP 8006).
- **For Educates:**
  - a domain, for example `workshops.example.com`;
  - one IP of the LoadBalancer range for its ingress, **chosen now**, for example the first one;
  - a wildcard DNS record `*.workshops.example.com` pointing to that IP;
  - a certificate for that domain (see [Certificates](#certificates)).

Sizing: one evaluation node needs 8 vCPU, 32 GB and 100 GB. See [Sizing](requirements.md#sizing).

## 2. Prepare the machine you deploy from

That machine must reach the Proxmox API (TCP 8006) and **every node** on TCP 50000 (Talos) and 6443 (Kubernetes).

| | A. Your workstation | B. A jump host |
|---|---|---|
| Use it when | It reaches the node network: same network, or a VPN that routes the whole node subnet | Anything else: a Linux machine in, or routed to, the node network |
| How | Run the commands in your clone | Drive it over SSH from your workstation with `scripts/jump-host.sh` |

Install these tools on that machine. On a jump host, you can put the binaries in `<work dir>/bin`: the scripts add it to the `PATH`.

| Tool | Version | Where |
|---|---|---|
| OpenTofu (or Terraform) | ≥ 1.6 | [opentofu.org](https://opentofu.org/docs/intro/install/) |
| `kubectl` | within one minor of Kubernetes (1.36–1.38) | [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| `talosctl` | same minor as Talos (1.14) | [Talos releases](https://github.com/siderolabs/talos/releases) |
| Educates CLI (`educates`) | same as Educates (tested with `4.0.0-alpha.13`) | [Educates releases](https://github.com/educates/educates-training-platform/releases) |
| `git`, `curl`, `jq`, `openssl` | any | your package manager |
| `tmux` | any, jump host only | your package manager |

## 3. Get the code and fill in your files

```shell
git clone https://github.com/educates/educates-terraform-modules.git
cd educates-terraform-modules/root-modules/educates-on-proxmox
```

Your site's values never go into the repository. Start from the templates in this directory:

| Template | Copy to | You fill in |
|---|---|---|
| `examples/single-host.tfvars.example` (one host, one VM), or `examples/ha.tfvars.example` (three hosts with Ceph) | `my-cluster.tfvars`, git-ignored | Proxmox URL, datastores, pool, network, nodes (Proxmox host, VM ID, IP, size), LoadBalancer range, storage |
| `proxmox.env.example` | `~/educates/proxmox.env`, outside the clone, mode 0600 | The token secrets, and the Ceph keys if you use Ceph CSI |
| `jump-host.env.example` | `jump-host.env`, git-ignored | Option B only: the jump host's SSH name and work directory |
| `backend_override.tf.example` | `backend_override.tf`, git-ignored | Optional: where the OpenTofu state lives |

```shell
cp examples/single-host.tfvars.example my-cluster.tfvars
mkdir -p -m 700 ~/educates && cp proxmox.env.example ~/educates/proxmox.env && chmod 600 ~/educates/proxmox.env
```

The comments in the examples explain each setting. The full list is in the [root module README](../../../root-modules/educates-on-proxmox/README.md#settings).

Keep everything with secrets out of the clone: `~/educates/` holds `proxmox.env`, and later your certificate files and `educates.yaml`.

The single-host example is tested on a Proxmox cluster and on a standalone Proxmox host (`local` and `local-lvm`).

## 4. Deploy the cluster

### Option A: from your workstation

```shell
set -a; . ~/educates/proxmox.env; set +a     # secrets, into this shell only
tofu init
scripts/preflight.sh --var-file my-cluster.tfvars    # checks tools, Proxmox, privileges, network: fix every FAIL
tofu plan -var-file=my-cluster.tfvars -out=my-cluster.tfplan   # review what will be created
tofu apply my-cluster.tfplan && rm my-cluster.tfplan            # 10–20 minutes; the plan file holds secrets
export KUBECONFIG=$PWD/kubeconfig-educates.yaml TALOSCONFIG=$PWD/talosconfig-educates   # educates = cluster_name
scripts/preflight.sh --var-file my-cluster.tfvars --after      # this machine reaches every node
scripts/e2e-test.sh                                             # storage, LoadBalancer, network: all PASS
```

### Option B: from a jump host

Fill in `jump-host.env` (`JUMP_HOST`, `JUMP_DIR`), then from your workstation:

```shell
scripts/jump-host.sh setup       # work directory on the jump host, a clone of this repository, state outside the clone
```

Copy your `my-cluster.tfvars` and `proxmox.env` into the work directory on the jump host:

```shell
scp my-cluster.tfvars ~/educates/proxmox.env <JUMP_HOST>:<JUMP_DIR>/
```

Then, from your workstation:

```shell
scripts/jump-host.sh preflight   # the checks, run on the jump host: fix every FAIL
scripts/jump-host.sh plan        # review what will be created
scripts/jump-host.sh apply       # runs inside tmux; `attach` re-attaches, exit its shell when done
scripts/jump-host.sh e2e         # storage, LoadBalancer, network: all PASS
scripts/jump-host.sh shell       # a shell there, with KUBECONFIG and TALOSCONFIG set
```

[Where you deploy from](requirements.md#where-you-deploy-from-workstation-or-jump-host) explains the jump host layout, and how the scripts keep everything inside the work directory.

### If the apply fails

An apply can always be run again: plan and apply once more, and it continues where it stopped. What already exists is kept. Common causes:

| Message | Cause | What to do |
|---|---|---|
| `connection refused` or a timeout to the API (`:6443`), right after the cluster is created | The API is still settling: on slow shared storage, etcd can lose its leader for a minute after bootstrap (see [requirements.md, Sizing](requirements.md#sizing)) | The module retries for about 8 minutes. If it still fails, wait a minute and apply again |
| `403 Permission check failed` | The token lacks a privilege | `scripts/preflight.sh` names the missing one ([Credentials](requirements.md#credentials)) |
| `the server could not find the requested resource` for a Cilium object | Cilium has not registered its CRDs yet | Apply again |

### What you get

- VMs named `<cluster_name>-<node>`, running Talos, in your pool.
- Kubernetes with Cilium, a LoadBalancer IP pool, and your StorageClasses, one of them the default.
- `kubeconfig-<cluster_name>.yaml` and `talosconfig-<cluster_name>`: admin credentials, keep them private. Use them with `KUBECONFIG` and `TALOSCONFIG`, as above. Never merge them into `~/.kube/config` or `~/.talos/config`.

## 5. Install Educates

Educates 4 is installed by an operator, with the Educates CLI. Its own documentation is in the [Educates installation guides](https://github.com/educates/educates-training-platform/tree/develop/project-docs/installation-guides). This section is the path tested on this cluster, with Educates `4.0.0-alpha.13`.

Run these commands where `kubectl` reaches the cluster, in `~/educates` (outside the clone). With a jump host:

- put the Educates CLI in `<work dir>/bin`, and copy your certificate files and `educates.yaml` to the work directory;
- open `scripts/jump-host.sh shell`, and `cd` to the work directory by its absolute path. In that shell, `~` is `<work dir>/home` (guest-env.sh), not the work directory: use absolute paths instead of `~/educates/...` below.

### Certificates

Every workshop session uses several host names under `*.<domain>`. Your users' browsers must **trust** the certificate's CA. Accepting a warning on the portal page is not enough: the session's background requests fail silently, and the session never opens ("Waiting for deployment…").

You need three files:

- `tls.crt`: a wildcard certificate for `*.<domain>` and `<domain>`, with its intermediate chain;
- `tls.key`: its key;
- `ca.crt`: the root CA certificate.

**a) From your organisation's CA (recommended).** Browsers already trust it. Ask for a server certificate (`serverAuth`) with those two names, then check it:

```shell
openssl x509 -in tls.crt -noout -subject -issuer -dates -ext subjectAltName
[ "$(openssl x509 -in tls.crt -noout -pubkey | openssl sha256)" = "$(openssl pkey -in tls.key -pubout | openssl sha256)" ] && echo "key matches"
awk '/BEGIN CERT/{n++} n>1' tls.crt > chain.pem && openssl verify -CAfile ca.crt -untrusted chain.pem tls.crt
```

**b) Your own lab CA**, when there is none. Users then import `ca.crt` into their browser or operating system.

```shell
DOMAIN=workshops.example.com
mkdir -m 700 ~/educates/lab-ca && cd ~/educates/lab-ca && umask 077     # outside the clone
# CA, 5 years. Name constraints: it can only sign names under $DOMAIN, even once imported into browsers.
openssl req -x509 -new -newkey rsa:3072 -nodes -sha256 -days 1825 -keyout ca.key -out ca.crt \
  -subj "/O=Educates/CN=Educates Lab CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;DNS:$DOMAIN"
# Wildcard certificate, 397 days (the maximum browsers accept).
openssl req -new -newkey rsa:2048 -nodes -sha256 -keyout tls.key -out tls.csr -subj "/CN=*.$DOMAIN"
printf "subjectAltName=DNS:*.%s,DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n" "$DOMAIN" "$DOMAIN" > tls.ext
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 397 -extfile tls.ext -out tls.crt
rm tls.csr tls.ext && chmod 644 ca.crt tls.crt
```

Keep `ca.key` where you created it: it never enters the cluster. Other options, such as Let's Encrypt with DNS-01, are in the Educates guide on secure HTTP connections.

### Configure and deploy

Write `~/educates/educates.yaml`, with your domain:

```yaml
apiVersion: cli.educates.dev/v1alpha1
kind: EducatesConfig
educatesClusterConfig:
  mode: Managed                             # Educates installs Contour, Kyverno and what it needs
  ingress:
    domain: workshops.example.com
    ingressClassName: contour
    controller:
      provider: BundledContour
      bundledContour:
        envoyServiceType: LoadBalancer      # takes an IP from the LoadBalancer range
    certificates:
      provider: StaticCertificate           # serves your certificate as is
      staticCertificate:
        tlsSecretRef:                       # yours; the operator copies it to educates-wildcard-tls
          name: educates-static-tls
          namespace: educates-installer
        caCertificateSecretRef:             # workshop pods trust this CA
          name: educates-static-ca
          namespace: educates-installer
  policyEnforcement:
    clusterPolicy:
      engine: Kyverno
    workshopPolicy:
      engine: Kyverno
    kyverno:
      provider: Bundled
secretsManager: {}
sessionManager:
  nodeCATrust:
    mode: Disabled                          # see below: it cannot work on Talos
```

Then deploy it, and give the ingress the IP you chose in step 1. Educates 4 has no setting for it, so pin it on the Service:

```shell
kubectl create namespace educates-installer
kubectl -n educates-installer create secret tls educates-static-tls --cert=tls.crt --key=tls.key
kubectl -n educates-installer create secret generic educates-static-ca --from-file=ca.crt=ca.crt
educates admin platform deploy --config educates.yaml          # about 5 minutes

kubectl -n contour annotate service contour-envoy lbipam.cilium.io/ips=<ingress IP> --overwrite
kubectl -n contour get service contour-envoy                    # EXTERNAL-IP is <ingress IP>
```

About the two Secrets and the node CA trust:

- **Secret names.** Do not name your Secret `educates-wildcard-tls`: that is the copy the operator makes and owns. The operator keeps its copy up to date, so to renew the certificate you only replace `educates-static-tls`, by hand or with a tool such as External Secrets ([operations.md](operations.md)).
- **`nodeCATrust`.** With a CA configured, Educates installs by default a `node-ca-injector` DaemonSet that writes the CA into `/etc/containerd/certs.d` on every node, so the nodes can pull images from registries served under your domain (workshops that run an image registry in the session). On Talos it cannot work: its pods are privileged with a `hostPath`, which Talos's default Pod Security (`baseline`) rejects, and Talos's containerd does not read that directory. The install still reports `Ready`, with the DaemonSet at 0 pods. Disable it. When nodes must trust your CA, for example with your own lab CA, add it to Talos instead, with a `TrustedRootsConfig` document in `extra_config_patches.all` of your tfvars:

  ```hcl
  extra_config_patches = {
    all = [<<-EOF
      apiVersion: v1alpha1
      kind: TrustedRootsConfig
      name: workshops-ca
      certificates: |
        -----BEGIN CERTIFICATE-----
        ...the content of ca.crt...
        -----END CERTIFICATE-----
      EOF
    ]
  }
  ```

### Run a sample workshop

```shell
# --initial 1 starts a session right away; --overdue 10m gives the first session on a node time to
# pull the 1.3 GB workshop image (the default timeout is 2 minutes).
educates deploy-workshop -f https://github.com/educates/lab-k8s-fundamentals/releases/latest/download/workshop.yaml \
  --initial 1 --overdue 10m
educates view-credentials        # the portal URL (educates-cli-ui.<domain>) and its password
# End-to-end check with a real session, from the root module directory. --ca-file only with your own lab CA.
scripts/e2e-test.sh --workshop --ca-file ~/educates/lab-ca/ca.crt
# jump host (absolute path; ~ is not expanded): scripts/jump-host.sh e2e --workshop --ca-file <work dir>/lab-ca/ca.crt
```

Open the portal URL and start the workshop. The first session on each node takes a few minutes, while the image downloads.

Known Educates 4 alpha behaviours on this cluster:

- **Workshop network policy.** The NetworkPolicy Educates puts in workshop namespaces blocks in-cluster traffic on Cilium. The module adds a Cilium policy that fixes it (`educates_workshop_egress_fix`, on by default).
- **Single-replica portal.** The training portal runs one replica: it is unavailable for a couple of minutes while its node is drained, for example during upgrades.

## Next

- **Day-2 operations.** See [operations.md](operations.md): upgrades, certificate renewal, scaling, uninstalling Educates, destroying the cluster.
- **Requirements reference.** See [requirements.md](requirements.md).
- **How the modules are built, and why.** See [design.md](design.md).

## Glossary

- **Talos API, `talosctl`.** How you manage Talos nodes: TCP 50000, authenticated with `talosconfig`. There is no SSH.
- **API VIP.** A floating IP for the Kubernetes API, held by one control-plane node at a time and announced with ARP. It is needed with more than one control-plane node.
- **KubePrism.** A local proxy on every Talos node that spreads requests across the API servers. Workloads inside the cluster use it, so they are not affected by the VIP moving.
- **L2 announcements.** Cilium answers ARP for LoadBalancer IPs, so they work on a plain network, with no external load balancer.
- **nocloud, Image Factory, schematic.** Talos reads its network settings from the Proxmox cloud-init drive (the "nocloud" platform). The disk image comes from the Talos Image Factory, built from a "schematic" that lists the system extensions.
- **Config contract.** The Talos configuration format version (`talos.config_contract`). Keep it fixed after the first apply.
- **Proxmox CSI, Ceph CSI.** Drivers that create Kubernetes volumes: as Proxmox disks attached to the VMs, or directly in Ceph (RBD for block volumes, CephFS for shared ones).
- **RADOS namespace, subvolume group.** Ways to give Kubernetes its own space inside a shared Ceph RBD pool or CephFS file system.
- **Managed mode (Educates).** Educates installs the services it needs (Contour, Kyverno) itself.
