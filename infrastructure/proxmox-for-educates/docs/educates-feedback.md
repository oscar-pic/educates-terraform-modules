# Feedback for the Educates team

Findings from running Educates 4 on these modules: Talos Linux on Proxmox VE, Cilium as the CNI, Cilium LoadBalancer IPs. Each item says:

- what we saw;
- why it matters;
- what could fix it on the Educates side;
- what this module does meanwhile.

Tested with Educates `4.0.0-alpha.13`, Cilium 1.20, Kubernetes 1.37, Talos 1.14.

| # | Item | Impact | Workaround here |
|---|---|---|---|
| 1 | Workshop NetworkPolicy blocks in-cluster traffic on Cilium | **Blocking**: workshop sessions cannot log in or reach the cluster | Yes, in the module (`educates_workshop_egress_fix`) |
| 2 | `blockedCidrs: []` cannot switch the policy off | Makes item 1 impossible to fix by configuration | — |
| 3 | No way to set annotations on the Envoy Service (fixed LoadBalancer IP) | Manual step after every install | Documented `kubectl annotate` |
| 4 | Bundled external-dns: no on-premises DNS providers | The wildcard record must be created by hand | Documented |
| 5 | Operator and training portal pods trigger Pod Security `restricted` warnings | Warning only; the docs say they meet `restricted` | — |
| 6 | Default startup timeout vs. first image pull | First session on a node times out | Documented `--overdue`, `--reserved` |
| 7 | Reserved sessions not created after recreating a portal | To confirm | — |
| 8 | Gateway API: CRD ownership and fixed addresses | Design input for the upcoming Gateway API support | — |
| 9 | `platform delete --purge` leaves resources behind, and can strand SecretCopiers | Uninstall needs manual steps | Documented uninstall order |

## 1. Workshop NetworkPolicy blocks in-cluster traffic on Cilium

**Seen.** The session manager creates `educates-network-policy` in every workshop environment and session namespace:

```yaml
policyTypes: [Egress]
egress:
- to: [{ipBlock: {cidr: 0.0.0.0/0, except: [169.254.169.254/32]}}]
- to: [{ipBlock: {cidr: ::/0, except: [fd00:ec2::254/128]}}]
```

The intent is "allow everything except the cloud metadata endpoint". Kubernetes leaves it to the implementation whether `ipBlock` matches pod IPs. **Cilium applies `ipBlock` only to traffic leaving the cluster**, so this policy cuts workshop pods off from:

- cluster DNS;
- in-cluster services;
- the Kubernetes API server.

Cilium logs `drop (Policy denied)` to CoreDNS `:53` and to the API server `:6443`. Calico matches pod IPs with `ipBlock`, so the issue does not show there. It should show on GKE Dataplane V2, which is Cilium.

**Effect.**

- The session cannot resolve `training-portal.<portal namespace>` (`getaddrinfo EAI_AGAIN`). The OAuth callback returns HTTP 500, and the user sees "Authentication failed" or stays on "Waiting for deployment…".
- `kubectl` in the workshop terminal cannot reach the API.

**Possible fixes.**

- Add an in-cluster egress rule to the policy: `- to: [{namespaceSelector: {}}]` covers pods and services with any CNI. The API server often runs on the host network, so it needs its address or port too, or the Cilium setting `policyCIDRMatchMode: nodes` documented.
- Or honour an empty `blockedCidrs` list as "no policy" (item 2).

**Here.** [`45-educates-compat.tf`](../45-educates-compat.tf) adds a `CiliumClusterwideNetworkPolicy` that gives in-cluster egress to pods in namespaces labelled `training.educates.dev/component in (environment, session)`. Cilium policies add up, so the result is what Educates intends: everything allowed except the metadata IP. Remove it once this is fixed.

**Reproduce.** On a kind cluster with Cilium as the CNI, start a workshop session and run `nslookup kubernetes.default` in its terminal.

## 2. `blockedCidrs: []` cannot switch the policy off

**Seen.** `SessionManager.spec.network.blockedCidrs: []` reaches the custom resource, but the operator treats an empty list as unset (`sessionmanager_controller.go`, `len(obj.Spec.Network.BlockedCIDRs) > 0`). The rendered `educates-config` keeps `clusterNetwork.blockCIDRs` with the metadata defaults.

**Why it matters.** On-premises clusters (Proxmox, bare metal) have no cloud metadata endpoint, so the policy protects nothing there. An empty list would be the natural way to drop it.

**Possible fix.** Distinguish "unset" from "empty", for example with a pointer to a slice, or an explicit `enabled: false`.

## 3. Annotations on the Envoy Service (fixed LoadBalancer IP)

**Seen.** `bundledContour` only exposes `envoyServiceType`. The operator sets the Service annotations itself (external-dns hostname), and there is no field for more.

**Why it matters.** On-premises, LoadBalancer IPs come from an in-cluster IPAM (Cilium LB-IPAM, MetalLB, kube-vip), which gives the first free IP of the pool. The wildcard record `*.<domain>` usually exists beforehand in an internal DNS, without external-dns, pointing to a fixed IP. Each IPAM pins the IP with its own annotation:

- `lbipam.cilium.io/ips`;
- `metallb.io/loadBalancerIPs`;
- `kube-vip.io/loadbalancerIPs`.

Clouds use annotations as well, for static IPs and internal load balancers.

**Possible fix.** A generic `envoyServiceAnnotations` map (and maybe labels) in `bundledContour`, passed to the Envoy Service as is. A field specific to one IPAM would not cover the others.

**Here.** After installing: `kubectl -n contour annotate service contour-envoy lbipam.cilium.io/ips=<ip>`. It survives operator reconciliation, but not a reinstall.

## 4. Bundled external-dns: no on-premises DNS providers

**Seen.** `BundledExternalDNS` and the ACME DNS-01 solver support Route53 and Cloud DNS. Cloudflare and AzureDNS are reserved but rejected.

**Why it matters.** Letting Educates write the record would remove the need to pre-create the wildcard and to pin the IP (item 3). On-premises DNS servers are typically BIND, PowerDNS or Windows DNS. external-dns supports RFC2136 and PowerDNS, for example.

**Possible fix.** Add RFC2136 (and maybe PowerDNS) to the bundled external-dns, and to the ACME DNS-01 solvers.

## 5. Pod Security `restricted` warnings

**Seen.** On Talos (default Pod Security: enforce `baseline`, warn `restricted`), restarting these Deployments prints `would violate PodSecurity "restricted:latest": seccompProfile ... must set securityContext.seccompProfile.type to "RuntimeDefault"`:

- `educates-installer` (operator), container `manager`;
- `training-portal`, container `portal`.

**Why it matters.** It is only a warning. But the docs say the operator pod meets the `restricted` level.

**Possible fix.** Set `seccompProfile: {type: RuntimeDefault}` on those pods.

## 6. Default startup timeout and the first image pull

**Seen.** With the defaults (`overdue: 2m`, no reserved sessions), the first session on a node timed out ("Startup timeout") while pulling `educates-base-environment` (1.3 GB, about 3 minutes on that link). Later sessions on the same node started in about 13 seconds.

**Possible fix.** A longer default `overdue`, or the image pre-puller on by default for `EducatesConfig` as for the narrow kinds. Or at least a hint in the timeout message.

**Here.** The getting-started guide deploys the sample workshop with `--reserved 1 --overdue 10m`.

## 7. Reserved sessions not created after recreating a portal (to confirm)

**Seen.** After deleting the `educates-cli` TrainingPortal and deploying the workshop again with `--reserved 1`, the portal logged `Updated status of workshop environment ... reserved=1`, but created no session, not even after a restart of its pod. With the previous portal, the same flag created the reserved session at once. Sessions on demand still worked. A brand-new portal with a different name (`e2e`, used by the end-to-end test) creates its sessions normally, every time. So it seems tied to recreating a portal with the same name.

Also in the portal log, at start-up: kopf cannot list CRDs (`customresourcedefinitions ... forbidden` for the `training-portal` service account), and then `changes ... will not be noticed`. We do not know yet whether the two are related.

## 8. Gateway API (for the upcoming support)

- **Fixed address.** `Gateway.spec.addresses` (type `IPAddress`) and `Gateway.spec.infrastructure.annotations` / `labels` cover what item 3 asks for Envoy. Exposing them in the Educates Gateway configuration would solve it the standard way. To check: whether agentgateway honours them.
- **CRD ownership.** These modules can install the Gateway API standard CRDs (`gateway_api.enabled`), which Cilium also needs when its Gateway API support is on. Agree who installs and upgrades them when Educates bundles agentgateway, so the two do not fight over versions.

## 9. Uninstall leaves resources behind

**Seen.** Uninstalling with `kubectl delete trainingportals --all` followed at once by `educates admin platform delete --yes --purge` left three things behind:

- **The `educates` namespace**, labelled `app.kubernetes.io/managed-by: educates-installer`, still holding the `educates-registry-hosts` ConfigMap.
- **The runtime CRDs** (`training.educates.dev`, `secrets.educates.dev`). This one is documented.
- **Four `SecretCopier` objects** (ingress secret and website theme, for the portal and the workshop environment), stuck with the `kopf.zalando.org/KopfFinalizerMarker` finalizer. The platform was removed before the secrets manager had cleaned them up, so nothing could remove the finalizer, and deleting their CRD hung until it was removed by hand.

A second uninstall the next day behaved differently. SecretCopiers of an already-deleted portal were still there after 3 minutes. That time they disappeared with the platform, and no finalizer got stuck. The cleanup of SecretCopiers is not reliable either way.

**Possible fixes.**

- `platform delete` waits for, or deletes, the SecretCopiers (and other kopf-managed objects) while the secrets manager still runs, or refuses while portals still exist.
- `--purge` removes the `educates` namespace it created.

**Here.** The getting-started guide documents the order: portals, then wait for the SecretCopiers to disappear, then the platform, then the namespace and CRDs.
