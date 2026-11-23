# Feedback for the Educates team

Findings from running Educates 4 on these modules: Talos Linux on Proxmox VE, Cilium as the CNI, Cilium LoadBalancer IPs. Items 15 to 18 come from installing it on a Talos cluster run by another team, without internet access from pods ([bring-your-own-cluster.md](bring-your-own-cluster.md)). Each item says:

- what we saw;
- why it matters;
- what could fix it on the Educates side;
- what this module does meanwhile.

Tested with Educates `4.0.0-alpha.13`, Cilium 1.20, Kubernetes 1.37, Talos 1.14.

## Checked again with `4.0.0-alpha.14`

On a local Talos 1.14 cluster (Talos in Docker, Cilium 1.20 with the same values as this module), following [getting-started.md](getting-started.md#5-install-educates) and [bring-your-own-cluster.md](bring-your-own-cluster.md) unchanged: the install, the inventory and a workshop session in a browser (terminals, console, editor, clickable actions) all worked.

| # | With alpha.14 |
|---|---|
| 1 | Still there: without the Cilium policy, a session cannot resolve the portal or reach the API |
| 2 | Still there: `blockedCidrs: []` reaches the `SessionManager`, the rendered `educates-config` keeps the metadata CIDRs |
| 3 | Still there: `bundledContour` gained an `operational` block (replicas, resources, node selector, tolerations, pod labels and annotations), but nothing for the Envoy Service |
| 5 | Partly fixed: the operator (`educates-installer`) now meets `restricted`. `training-portal`, `secrets-manager` and `session-manager` still lack `seccompProfile` (the `educates` namespace is now labelled `privileged`, so only the portal's warning shows) |
| 6 | Still there: a portal deployed without `--overdue` gets `overdue: 2m` |
| 7 | Still there, and wider: a new portal with `--reserved 1` gets no reserved session, and raising `reserved` on an existing portal (to 2) created none either; the portal logs `Updated status of workshop environment ... reserved=2` and nothing else. The kopf warning about listing CRDs is gone |
| 13 | Still there: Contour `v1.33.8`, same `contour bootstrap --xds-address=contour` with no `--dns-lookup-family` |
| 14, 16 | Still there: Kyverno takes only `provider`, its admission controller runs one replica. New: the install checks Kyverno and waits for it. Also found: on a graceful stop Kyverno removes its webhooks, so policies are not enforced until it is back ([item 14](#14-bundled-kyverno-one-replica-webhooks-that-fail-closed)) |
| 17 | Partly fixed, see [item 17](#17-nodecatrust-auto-installs-a-node-ca-injector-that-cannot-run-on-talos) |
| 18 | Still there: `educates:session-manager:admin` binds `admin` cluster-wide. New: narrower roles for the portal and console, and two ValidatingAdmissionPolicies |

Not re-checked: 4, 8, 9, 10, 11, 12 and 15. The classic instructions renderer is gone in alpha.14; the sample workshop `lab-k8s-fundamentals` already uses Hugo and renders fine.

| # | Item | Impact | Workaround here |
|---|---|---|---|
| 1 | Workshop NetworkPolicy blocks in-cluster traffic on Cilium | **Blocking**: workshop sessions cannot log in or reach the cluster | Yes, in the module (`educates_workshop_egress_fix`) |
| 2 | `blockedCidrs: []` cannot switch the policy off | Makes item 1 impossible to fix by configuration | — |
| 3 | No way to set annotations on the Envoy Service (fixed LoadBalancer IP) | Manual step after every install | Documented `kubectl annotate` |
| 4 | Bundled external-dns: no on-premises DNS providers | The wildcard record must be created by hand | Documented |
| 5 | Operator and training portal pods trigger Pod Security `restricted` warnings | Warning only; the docs say they meet `restricted` | — |
| 6 | Default startup timeout vs. first image pull | First session on a node times out | Documented `--overdue`, `--reserved` |
| 7 | Reserved sessions not created for a new portal deployed with `--reserved` | No warm session for the first user; sessions start on demand | `--initial 1` |
| 8 | Gateway API: CRD ownership and fixed addresses | Design input for the upcoming Gateway API support | — |
| 9 | `platform delete --purge` leaves resources behind, and can strand SecretCopiers | Uninstall needs manual steps | Documented uninstall order |
| 10 | The training portal is a single replica with a `ReadWriteOnce` volume | Portal down for about 2 minutes whenever its node is drained (upgrades, maintenance) | Documented: upgrade outside class hours |
| 11 | Proposal: a documentation section for on-premises clusters | Most findings here are not specific to Proxmox or Talos | — |
| 12 | Proposal: a cluster readiness check in the Educates CLI | Users find cluster problems only when a workshop fails | `scripts/e2e-test.sh` in this repository |
| 13 | The bundled Envoy looks up the bare name `contour` in the site DNS, every few seconds | None functionally; constant noise in the DNS servers' logs | — |
| 14 | Bundled Kyverno: one replica, webhooks that fail closed | After losing the node Kyverno runs on, no Educates pod can be created for minutes, and the training portal stays down until restarted by hand. On a planned stop (drain), the opposite: workshop policies are not enforced until Kyverno is back | Documented `rollout restart`; upgrade outside class hours |
| 15 | `platform render` does not show what the operator installs | A cluster owner cannot review Kyverno, Contour, their webhooks and roles before the install | `scripts/educates-inventory.sh` right after the install |
| 16 | The bundled Kyverno chart takes no values | Its webhooks, replicas and resources cannot be adapted to a shared cluster | — |
| 17 | `nodeCATrust: Auto` installs a node CA injector that cannot run on Talos | alpha.13: refused by Pod Security, install still `Ready`. alpha.14: install times out | Documented `nodeCATrust.mode: Disabled`; the e2e check flags workloads not ready |
| 18 | The session manager is bound to `admin` cluster-wide | Hard to accept on a cluster that also runs other workloads | Documented for the cluster owner's review |

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

## 7. Reserved sessions not created for a new portal

**Seen.** After deleting the `educates-cli` TrainingPortal and deploying the workshop again with `--reserved 1`, the portal logged `Updated status of workshop environment ... reserved=1`, but created no session, not even after a restart of its pod. With the previous portal, the same flag created the reserved session at once. Sessions on demand still worked. A brand-new portal with a different name (`e2e`, used by the end-to-end test) creates its sessions normally, every time. On a fresh cluster, a brand-new portal deployed with `--reserved 1` again created no reserved session. So it is not about recreating a portal with the same name:

- a new portal with `--reserved 1` gets no reserved session;
- a new portal with `--initial 1` gets its session;
- updating an existing portal with `--reserved 1` creates the reserve at once.

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

A third uninstall, on a freshly built cluster, also left a `ValidatingWebhookConfiguration` of Kyverno's, `kyverno-cleanup-validating-webhook-cfg` (`failurePolicy: Fail`, label `webhook.kyverno.io/managed-by: kyverno`). Kyverno's controllers create these webhooks themselves, so `helm uninstall` does not remove them, and this one outlived its controller and the Service it calls.

**Possible fixes.**

- `platform delete` waits for, or deletes, the SecretCopiers (and other kopf-managed objects) while the secrets manager still runs, or refuses while portals still exist.
- `--purge` removes the `educates` namespace it created.
- Removing the bundled Kyverno also removes the webhook configurations labelled `webhook.kyverno.io/managed-by: kyverno`.

**Here.** [operations.md](operations.md#uninstalling-educates) documents the order: portals, then wait for the SecretCopiers to disappear, then the platform, then the namespace, the CRDs and Kyverno's webhooks, and a final check that nothing is left.

## 10. The training portal is a single point of failure during node maintenance

**Seen.** The training portal runs one replica with its database on a `ReadWriteOnce` volume. During a rolling Talos upgrade, its node was drained:

- the pod moved to another node;
- the new pod waited for the volume to detach from the old node ("Waiting for detach … Volume is already used by pod(s)").

The portal answered 503 for about 2 min 20 s, then came back with its data intact. Sessions already running were not affected: they run in their own pods. But nobody could log in or start a workshop in that window.

**Why it matters.** Kubernetes and Talos upgrades, and any node maintenance, are routine on a multi-node cluster. Here the rest of the stack stayed up through them: the API through KubePrism, the ingress, the workshop sessions.

**Possible fixes.** Portal high availability: more than one replica, with a database that allows it (an external PostgreSQL, or a `ReadWriteMany` volume if the portal can share it safely). Or a PodDisruptionBudget plus a quicker hand-over. At least, document it as a maintenance-window consideration.

## 11. Proposal: a documentation section for on-premises clusters

Most findings in this document are not specific to Proxmox or Talos. They apply to any on-premises cluster, whether on bare metal, VMware or another hypervisor, and many to any cluster with Cilium (including GKE Dataplane V2):

- the workshop NetworkPolicy on Cilium (item 1);
- pinning the ingress IP with an in-cluster IPAM: Cilium LB-IPAM, MetalLB, kube-vip (item 3);
- on-premises DNS for the wildcard record (item 4);
- browsers must trust the CA: accepting a warning on the portal is not enough, because session requests to other host names fail silently;
- the first session on a node exceeding the default startup timeout (item 6);
- uninstall leftovers (item 9);
- the single-replica portal during node maintenance (item 10).

A section like "Installing on premises" in the Educates installation guides would reach users of every platform. Infrastructure repositories like this one only reach users of one provider.

## 12. Proposal: a cluster readiness check in the Educates CLI

`root-modules/educates-on-proxmox/scripts/e2e-test.sh` in this repository checks any cluster before and after installing Educates. It runs in about 2 minutes, and cleans up everything it creates:

- a default StorageClass, with a volume created, written and deleted;
- `LoadBalancer` Services getting an IP and answering;
- pod DNS and egress;
- a replica of the Educates workshop namespace and NetworkPolicy reaching cluster DNS, Services and the API;
- with Educates installed, a real workshop session over HTTPS.

Today users discover these problems when a workshop fails. Something like `educates admin cluster check` in the Educates CLI, built from these checks, would tell them before they install, on any platform. The script is offered as a starting point.

## 13. The bundled Envoy looks up the bare name `contour` in the site DNS

**What we saw.** The site's DNS servers, outside the cluster, receive queries for `contour.` (the bare name, with no domain) from the cluster nodes. On an otherwise idle cluster this was about 12 queries a minute. Nothing breaks.

**Cause (confirmed with the CoreDNS query log).** The queries come from the `contour-envoy` pods, in namespace `contour`. Their init container bootstraps Envoy with `contour bootstrap --xds-address=contour`, and no `--dns-lookup-family`. So the Envoy cluster `contour` is `STRICT_DNS` on the short name `contour`, with the default lookup family, and Envoy re-resolves it every few seconds. Each refresh does two lookups:

- **The A lookup** resolves through the first search domain, `contour.contour.svc.cluster.local`.
- **The AAAA lookup**, on an IPv4-only cluster, finds no address there. The resolver then walks the whole search list, and finally asks for `contour.` itself. CoreDNS forwards that to the upstream DNS. On Talos this goes through the node's host DNS, so the site DNS sees the node IPs.

The CoreDNS log shows this sequence for `AAAA`, at every refresh: `contour.contour.svc.cluster.local.` → `contour.svc.cluster.local.` → `contour.cluster.local.` (NXDOMAIN) → `contour.`.

Seen with Contour `v1.33.7`, bundled by Educates `4.0.0-alpha.13`.

**Why it matters.** It is harmless, but it sends a cluster-internal name to the organisation's DNS servers, constantly. DNS administrators notice it and ask about it.

**Possible fixes**, in the arguments of the bundled Envoy's init container (`contour bootstrap`):

- `--dns-lookup-family=v4` on IPv4-only clusters (the option exists: v4, v6, auto or all);
- or a fully qualified xDS address: `--xds-address=contour.<namespace>.svc.cluster.local.`, with the trailing dot, so no search list is walked.

## 14. Bundled Kyverno: one replica, webhooks that fail closed

**What we saw.** We powered off one of three Proxmox hosts, with Proxmox HA on. One worker on it ran the bundled Kyverno (every controller, one replica each), the training portal and a workshop session. Kubernetes evicted the pods after 5 minutes. The workshop session started again on another worker. The portal did not: its ReplicaSet failed to create the new pod:

```text
Error creating: Internal error occurred: failed calling webhook "vpol.validate.kyverno.svc-fail-…":
failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/vpol/disallow-capabilities/…"
```

Kyverno came back on another node a minute later. By then, the ReplicaSet controller was backing off: the portal was still down six minutes later, until `kubectl rollout restart deployment/training-portal`. The rest of the cluster had recovered: API, nodes and session.

**With alpha.14**, on a local Talos cluster, the admission controller still runs one replica. We tried both ways of losing it, and checked a pod that the workshop policy rejects (`pause`, no security context) in a session namespace (`restricted`):

| Kyverno lost by | Its webhooks | A pod in a session namespace | Pods elsewhere |
|---|---|---|---|
| Abrupt node failure (`docker kill` of the node) | Stay registered | Every pod refused: `failed calling webhook "vpol.validate.kyverno.svc-fail-…"`, for about 6 minutes, until Kyverno runs on another node | Not affected |
| Graceful shutdown (scaled to 0; a drain or a controlled reboot also stops it gracefully) | Removed by Kyverno on shutdown (4 `vpol` webhooks to 0), registered again when it starts | **Admitted, against the policy** | Not affected |

So the bundled Kyverno fails closed on a node failure, and **fails open** on a planned stop: while Kyverno moves during a drain or an upgrade, workshop sessions run without their security policy.

**Why it matters.** A single node failure blocks every pod that Educates creates, including new workshop sessions. And it can leave the portal down until someone intervenes. The portal is already a single replica (item 10). A planned stop of Kyverno's node, which is routine (upgrades), leaves the workshop policies unenforced for as long as Kyverno takes to start again.

**Possible fixes:**

- Run the bundled Kyverno admission controller with three replicas, spread over nodes (anti-affinity or topology spread), with a PodDisruptionBudget. This is the Kyverno project's recommendation for production, and it covers both cases: a drain cannot stop the last replica, and a node failure leaves two.
- Or, for the pod-security policies, a `failurePolicy` that does not block the platform's own components while Kyverno is unavailable.
- And let the operator notice a Deployment that cannot create its pod, and retry.

## 15. `platform render` does not show what the operator installs

**What we saw.** The cluster owner asked to review everything Educates would create at cluster scope before the install: admission webhooks, policies, CRDs, ClusterRoles, the Envoy Service. `educates admin platform render --config educates.yaml` printed 44 lines: empty operator chart values and the `EducatesClusterConfig`, `SecretsManager` and `SessionManager` resources. Contour and Kyverno, with their webhooks, CRDs and roles, are installed later by the operator, from charts embedded in it, with values it computes. `helm template` of the `educates-installer` chart adds the operator itself (4 CRDs, 4 ClusterRoles), still not the cluster services.

**Why it matters.** On a cluster that also runs other services, the owner wants to know what a webhook that fails closed will intercept before it exists. We could only offer to install, list what was created (`scripts/educates-inventory.sh` in this repository) and uninstall if needed.

**Possible fixes:**

- An option of `platform render` that also renders the bundled charts with the values the operator would use (for example `--include-cluster-services`).
- Or a page in the documentation listing, per release, what each bundled chart creates at cluster scope and with which values.

## 16. The bundled Kyverno chart takes no values

**What we saw.** The operator installs Kyverno with the chart defaults; the only value it sets is the image registry. Its `webhooks.namespaceSelector` excludes `kube-system` only, its admission controller runs one replica (item 14), and its resources cannot be set. In our test the result was acceptable: the webhooks that check workloads only apply to namespaces labelled by Educates, and the ones that apply everywhere only concern Kyverno's own resource types. But the cluster owner asked to exclude a list of their namespaces explicitly, and there was no way to do it.

**Possible fix.** A pass-through for the Kyverno chart values in the `EducatesClusterConfig` (as for other bundled services), or at least for the webhook namespace selector, the replicas and the resources.

## 17. `nodeCATrust: Auto` installs a node CA injector that cannot run on Talos

**alpha.14.** Two of the fixes below are in: the `educates` namespace is labelled `privileged`, and the install no longer reports `Ready`, it waits for the DaemonSet and times out (`SessionManager/cluster ... phase=Installing`). On Talos the pods still cannot start: `failed to mkdir "/etc/containerd/certs.d": mkdir /etc/containerd/certs.d: read-only file system` (`CreateContainerError`). The third fix, documenting where `nodeCATrust` does not apply, still holds. What follows is what we saw with alpha.13.

**What we saw.** With a CA configured (`staticCertificate.caCertificateSecretRef`), the session manager installs the `node-ca-injector` DaemonSet by default. Its pods are privileged and mount `/etc/containerd/certs.d` from the host. Talos enforces Pod Security `baseline` cluster-wide by default, so every pod was refused:

```text
Error creating: pods "node-ca-injector-…" is forbidden: violates PodSecurity "baseline:latest":
hostPath volumes (volume "containerd-certs-d"), privileged (container "sync" must not set securityContext.privileged=true)
```

The install finished, and every platform resource reported `Ready`, with the DaemonSet at 0 of 6 pods. We noticed only because the cluster owner did. On Talos the injector could not work anyway: Talos's containerd does not read `/etc/containerd/certs.d`. Nodes trust a CA through the Talos machine configuration (`TrustedRootsConfig`). `nodeCATrust.mode: Disabled` removed it cleanly.

**Possible fixes:**

- Report a condition that is not ready (or a warning) on the `SessionManager` when the DaemonSet cannot create its pods.
- Label its namespace for the Pod Security level it needs, as Educates does for workshop namespaces with the `pod-security-standards` engine, or document that it needs `privileged`.
- Document `nodeCATrust` with the distributions where it does not apply (Talos, and others with an immutable containerd configuration).

## 18. The session manager is bound to `admin` cluster-wide

**What we saw.** The ClusterRoleBinding `educates:session-manager:admin` binds the ServiceAccount `educates/session-manager` to the built-in `admin` ClusterRole for the whole cluster, which includes reading and writing Secrets in every namespace. The operator itself runs with a fine-grained ClusterRole generated from what it installs. The cluster owner accepted it for a temporary trial only.

**Why it matters.** Educates recommends a dedicated cluster, and this is one reason. But for trials, or for organisations that run Educates next to other services, it is the first thing a security review stops at.

**Possible fix.** Bind `admin` only in the namespaces the session manager creates (it creates them, so it can add the RoleBinding), and keep cluster-wide only what it needs at cluster scope, as was done for the operator.
