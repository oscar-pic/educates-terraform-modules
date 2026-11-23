# Trying Educates on a local Talos cluster

A Talos cluster in Docker, on your own computer, close enough to the clusters these modules build to try things before taking them to Proxmox:

- a new Educates release, with the steps of [getting-started.md](getting-started.md#5-install-educates) and [bring-your-own-cluster.md](bring-your-own-cluster.md);
- the scripts of the root module (`e2e-test.sh`, `educates-inventory.sh`);
- procedures such as [uninstalling Educates](operations.md#uninstalling-educates), draining a node or losing one.

It uses the same Talos version, the same Cilium chart and values (KubePrism, kube-proxy replacement, L2 announcements) and the same Educates configuration as the modules. It does not test Proxmox, the Terraform modules themselves, the storage drivers (it uses local volumes instead), the API VIP or Talos upgrades.

Tested on macOS with Docker Desktop (Apple silicon), `talosctl` 1.14.5, Cilium 1.20.4 and Educates `4.0.0-alpha.14`. On Linux with Docker Engine, the computer reaches the containers' IPs directly, so the proxy of step 3 should not be needed (not tested).

## What you need

- **Docker Desktop** with at least **24 GB of memory** (Settings, Resources, then Apply). The cluster below asks for 19 GiB: one control plane with 3 GiB, two workers with 8 GiB each. Docker shares CPUs, so asking for more CPUs than you have is fine.
- **About 20 GB of free disk** for the node images and the workshop image (1.3 GB per worker).
- The tools of [getting-started.md](getting-started.md#2-prepare-the-machine-you-deploy-from): `talosctl` (its version is the Talos version of the cluster), `kubectl`, `helm`, `jq`, `openssl` and the Educates CLI. The Cilium CLI is optional.
- A clone of this repository, here in `$REPO`.

## 1. Work directory

Everything goes in one directory, outside the clone, so removing it removes everything. An environment file points every tool at this cluster only, never at `~/.kube/config` or `~/.talos/config`:

```shell
REPO=~/src/educates-terraform-modules        # your clone
W=~/educates-local
mkdir -m 700 $W && mkdir $W/bin               # put the Educates CLI in $W/bin
cat > $W/env.sh <<EOF
# Load it in each terminal, with a dot (do not run it): . $W/env.sh
export W=$W REPO=$REPO
export KUBECONFIG=$W/kubeconfig TALOSCONFIG=$W/talosconfig PATH=$W/bin:\$PATH
# The proxy of step 3 reaches the LoadBalancer IPs; the Kubernetes API (127.0.0.1) stays direct.
export https_proxy=http://127.0.0.1:8888 http_proxy=http://127.0.0.1:8888 no_proxy=127.0.0.1,localhost
export HTTPS_PROXY=\$https_proxy HTTP_PROXY=\$http_proxy NO_PROXY=\$no_proxy
EOF
. $W/env.sh
```

## 2. Create the cluster

Cilium is installed as part of the Talos configuration, as the modules do: render the chart with the module's values, then wrap it in a Talos patch for the control plane.

```shell
cd $W
sed -e 's/${operator_replicas}/2/' -e 's/${gateway_api_enabled}/false/' -e 's/${hubble_enabled}/false/' \
  $REPO/infrastructure/proxmox-for-educates/templates/cilium-values.yaml.tftpl > cilium-values.yaml
helm template cilium cilium --repo https://helm.cilium.io --version 1.20.4 -n kube-system \
  -f cilium-values.yaml > cilium.yaml
{ cat <<'EOF'
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
---
apiVersion: v1alpha1
kind: KubeInlineManifestConfig
name: cilium
manifest: |
EOF
  sed 's/^/  /' cilium.yaml; } > patch-cp.yaml

talosctl cluster create docker --name educates-local --state $W/state --talosconfig-destination $W/talosconfig \
  --workers 2 --cpus-controlplanes 2 --memory-controlplanes 3GiB --cpus-workers 4 --memory-workers 8GiB \
  --config-patch-controlplanes @patch-cp.yaml
talosctl config node 10.5.0.2                  # the control plane, so talosctl and e2e-test.sh need no -n
kubectl wait --for=condition=Ready nodes --all --timeout=600s
```

The patch uses the Talos 1.14 documents. The older `cluster.network.cni` and `cluster.proxy` keys are refused when Talos also generates these documents. The patch applies to the control plane only.

The nodes are on a Docker network, `10.5.0.0/24` by default: the control plane is `10.5.0.2`, the workers follow. If that range is used on your network, `talosctl cluster create docker --help` lists the option to pick another one, and every `10.5.0.x` below changes with it.

## 3. LoadBalancer IPs, storage and the proxy

```shell
# LoadBalancer IPs from the end of the Docker network, announced on the nodes' interface.
cat <<'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  blocks:
  - start: 10.5.0.200
    stop: 10.5.0.210
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default
spec:
  interfaces: ["^eth0$"]
  loadBalancerIPs: true
EOF

# Local volumes on each node, as the default StorageClass. Talos keeps data under /var.
curl -sSLf https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml \
  | sed 's|/opt/local-path-provisioner|/var/local-path-provisioner|' | kubectl apply -f -
kubectl label namespace local-path-storage pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# An HTTP proxy inside the cluster's Docker network, published only on 127.0.0.1:8888.
docker run -d --name educates-local-proxy --network educates-local -p 127.0.0.1:8888:8888 --restart unless-stopped \
  alpine:3.22 sh -c 'apk add -q --no-cache tinyproxy && printf "Port 8888\nListen 0.0.0.0\nTimeout 600\nAllow 0.0.0.0/0\nConnectPort 443\nConnectPort 80\n" > /etc/tinyproxy/tinyproxy.conf && exec tinyproxy -d'
```

Docker Desktop runs the containers inside a virtual machine, so your computer cannot reach `10.5.0.x`. The proxy can, and `env.sh` sends `curl`, the Educates CLI and the scripts through it. It also resolves host names for them, from inside Docker.

At this point the cluster is ready, and `$REPO/root-modules/educates-on-proxmox/scripts/e2e-test.sh` (without `--workshop`) should report no failures. It warns that the Cilium policy `educates-allow-in-cluster` is missing until step 4 applies it.

## 4. Install Educates

**Domain.** The domain is `10-5-0-200.nip.io`. nip.io is a public wildcard DNS service: every name under it resolves to the IP it spells, here `10.5.0.200`, the IP Envoy will take. Some routers and DNS filters refuse answers with private IPs ("DNS rebinding protection"). If `nslookup x.10-5-0-200.nip.io` returns no address, allow `nip.io` there, or use another such service (`sslip.io`).

**Certificate.** Create a lab CA as in [getting-started.md](getting-started.md#certificates), option b), with `DOMAIN=10-5-0-200.nip.io`, in `$W/lab-ca` instead of `~/educates/lab-ca`.

**Configuration.** Write `$W/educates.yaml` exactly as in [getting-started.md](getting-started.md#configure-and-deploy), with `domain: 10-5-0-200.nip.io`. Keep `nodeCATrust.mode: Disabled`: it cannot work on Talos.

```shell
cd $W
# Optional: the state of every CRD before the install, for the owner-style review afterwards.
$REPO/root-modules/educates-on-proxmox/scripts/educates-inventory.sh --snapshot crds.before

kubectl create namespace educates-installer
kubectl -n educates-installer create secret tls educates-static-tls --cert=lab-ca/tls.crt --key=lab-ca/tls.key
kubectl -n educates-installer create secret generic educates-static-ca --from-file=ca.crt=lab-ca/ca.crt
educates admin platform deploy --config educates.yaml          # about 5 minutes
kubectl -n contour annotate service contour-envoy lbipam.cilium.io/ips=10.5.0.200 --overwrite

# The Cilium policy workshops need (the module adds it on Proxmox; here, apply it by hand).
awk '/^```yaml$/{f=1;b="";next} f&&/^```$/{if(b~/CiliumClusterwideNetworkPolicy/){printf "%s",b;exit} f=0;next} f{b=b $0 "\n"}' \
  $REPO/infrastructure/proxmox-for-educates/docs/bring-your-own-cluster.md | kubectl apply -f -

# Optional: what the install created, as a cluster owner would review it.
$REPO/root-modules/educates-on-proxmox/scripts/educates-inventory.sh --before crds.before > inventory.txt
```

## 5. Run a workshop

```shell
educates deploy-workshop -f https://github.com/educates/lab-k8s-fundamentals/releases/latest/download/workshop.yaml \
  --initial 1 --overdue 10m
$REPO/root-modules/educates-on-proxmox/scripts/e2e-test.sh --workshop --ca-file $W/lab-ca/ca.crt
```

The e2e check starts a real session and checks it end to end, without a browser.

**In a browser.** The browser must reach the cluster through the proxy and trust the lab CA:

- a proxy extension (for example FoxyProxy) with a rule that sends `*.10-5-0-200.nip.io` to the HTTP proxy `127.0.0.1:8888`;
- `ca.crt` imported into the operating system or the browser. Its name constraints limit it to `10-5-0-200.nip.io`.

`educates view-credentials` shows the portal URL and its password. **Remove both the rule and the CA when you finish** (see [Removing everything](#removing-everything)).

## What you can try on it

- **A new Educates release.** Put its CLI in `$W/bin` and run `educates admin platform deploy` again, or uninstall and install from scratch.
- **Losing a node.** `docker kill educates-local-worker-1` is an abrupt failure; `docker start educates-local-worker-1` brings it back. A drain is `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`, then `kubectl uncordon <node>`.
- **Uninstalling Educates**, following [operations.md](operations.md#uninstalling-educates). To see exactly what an uninstall leaves, list every object in the cluster before and after, and compare the two lists:

  ```shell
  for r in $(kubectl api-resources --verbs=list -o name | grep -vE '^(events|events.events.k8s.io|leases.coordination.k8s.io|endpoints|endpointslices.discovery.k8s.io)$'); do
    kubectl get "$r" -A --no-headers -o custom-columns='NS:.metadata.namespace,N:.metadata.name' 2>/dev/null | awk -v r="$r" '{print r, $1, $2}'
  done | LC_ALL=C sort > objects.$(date +%H%M)
  ```

  Then `LC_ALL=C comm -3 objects.<before> objects.<after>`.

## After restarting your computer

The nodes keep their state in their containers, but the containers do not start by themselves (the proxy does). Start Docker Desktop, then:

```shell
. ~/educates-local/env.sh
docker start educates-local-controlplane-1 educates-local-worker-1 educates-local-worker-2 educates-local-proxy
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Ready nodes --all --timeout=600s
kubectl get pods -A | grep -vE 'Running|Completed'               # wait until only the header is left
```

## Removing everything

```shell
. ~/educates-local/env.sh
talosctl cluster destroy --name educates-local --state $W/state
docker rm -f educates-local-proxy
rm -rf $W
```

Then remove the proxy rule from the browser extension, and the lab CA from where you imported it. On macOS, if you imported it into the System keychain: `sudo security delete-certificate -c "Educates Lab CA" /Library/Keychains/System.keychain`. If you raised Docker Desktop's memory only for this, lower it again.
