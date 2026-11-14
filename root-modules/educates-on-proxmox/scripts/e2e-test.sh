#!/usr/bin/env bash
# End-to-end test of a cluster built by educates-on-proxmox, and of Educates on it.
#
# Run it where you operate the cluster (workstation or jump host), with KUBECONFIG and
# TALOSCONFIG pointing to the files the deployment wrote. On a jump host:
# `scripts/jump-host.sh e2e [options]`.
#
#   scripts/e2e-test.sh                         # cluster, storage, LoadBalancer, network, Educates if installed
#   scripts/e2e-test.sh --workshop --ca-file root-ca.crt   # also a real workshop session in its own portal
#
# It creates its resources in namespaces named e2e-* (and, with --workshop, a training portal
# named "e2e"), and deletes them on exit, also when a check fails (unless --keep).
# It never changes anything else.
#
# Options:
#   --storage-class NAME    StorageClass to test (default: the default one). Repeat for several.
#   --all-storage-classes   Test every StorageClass.
#   --workshop              Deploy a sample workshop in a portal named "e2e" and test a session.
#   --workshop-url URL      Workshop definition (default: Educates lab-k8s-fundamentals).
#   --ca-file FILE          CA certificate to verify HTTPS with (default: the system trust store).
#   --image IMAGE           Test image (default: registry.k8s.io/e2e-test-images/agnhost:2.53),
#                           for clusters that pull through a mirror.
#   --keep                  Do not delete the test resources (for debugging).
#
# Exit code: 0 if no check failed.

set -u

STORAGE_CLASSES=""
ALL_SC=false
WORKSHOP=false
WORKSHOP_URL="https://github.com/educates/lab-k8s-fundamentals/releases/latest/download/workshop.yaml"
CA_FILE=""
IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.53"
KEEP=false

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --storage-class) STORAGE_CLASSES="$STORAGE_CLASSES ${2:?}"; shift 2 ;;
    --all-storage-classes) ALL_SC=true; shift ;;
    --workshop) WORKSHOP=true; shift ;;
    --workshop-url) WORKSHOP_URL="${2:?}"; shift 2 ;;
    --ca-file) CA_FILE="${2:?}"; shift 2 ;;
    --image) IMAGE="${2:?}"; shift 2 ;;
    --keep) KEEP=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

FAILS=0; WARNS=0
if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'; else G=; Y=; R=; B=; N=; fi
pass() { echo "  ${G}PASS${N} $*"; }
warn() { echo "  ${Y}WARN${N} $*"; WARNS=$((WARNS + 1)); }
fail() { echo "  ${R}FAIL${N} $*"; FAILS=$((FAILS + 1)); }
info() { echo "  ${B}INFO${N} $*"; }
section() { echo; echo "${B}== $*${N}"; }
have() { command -v "$1" >/dev/null 2>&1; }

RUN_ID="$(date +%H%M%S)$$"
NS="e2e-$RUN_ID"                 # workloads, storage, LoadBalancer
NS_EDU="e2e-$RUN_ID-educates"    # replica of an Educates workshop namespace
PORTAL="e2e"
CREATED_PORTAL=false
CURL_CA=""; [ -n "$CA_FILE" ] && CURL_CA="--cacert $CA_FILE"

cleanup() {
  if $KEEP; then
    echo; info "--keep: left namespaces $NS, $NS_EDU$($CREATED_PORTAL && echo " and portal $PORTAL")"
    return
  fi
  echo; echo "${B}== Cleanup${N}"
  $CREATED_PORTAL && kubectl delete trainingportal "$PORTAL" --wait=true --timeout=300s >/dev/null 2>&1
  kubectl delete namespace "$NS" "$NS_EDU" --ignore-not-found --wait=true --timeout=300s >/dev/null 2>&1
  info "test resources deleted"
}
trap cleanup EXIT

# kexec <namespace> <pod> <shell command>: runs in the pod, prints the last output line.
kexec() { kubectl -n "$1" exec "$2" -- sh -c "$3" 2>&1 | tail -n 1; }

# Pod and container spec shared by every test pod (meets the "restricted" Pod Security level).
pod_spec() {
  cat <<EOF
    securityContext: {runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
    containers:
    - name: main
      image: $IMAGE
      args: $1
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
EOF
}

###############################################################################
section "Prerequisites"
###############################################################################

for t in kubectl curl jq; do
  if have "$t"; then pass "$t"; else fail "$t not found"; fi
done
have talosctl && pass "talosctl" || warn "talosctl not found: the Talos health check is skipped"
if $WORKSHOP && ! have educates; then fail "--workshop needs the educates CLI"; fi
if [ -n "$CA_FILE" ] && [ ! -f "$CA_FILE" ]; then fail "--ca-file $CA_FILE not found"; fi
if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  fail "cannot reach the Kubernetes API (KUBECONFIG=${KUBECONFIG:-unset})"
fi
[ "$FAILS" -eq 0 ] || { echo; echo "Fix the prerequisites and run again."; trap - EXIT; exit 1; }
info "cluster: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

###############################################################################
section "Cluster"
###############################################################################

NODES="$(kubectl get nodes --no-headers 2>/dev/null)"
TOTAL=$(echo "$NODES" | grep -c .)
READY=$(echo "$NODES" | awk '$2 == "Ready"' | grep -c .)
[ "$TOTAL" -gt 0 ] && [ "$READY" -eq "$TOTAL" ] && pass "nodes: $READY/$TOTAL Ready" || fail "nodes: $READY/$TOTAL Ready"

if have talosctl; then
  if talosctl health --wait-timeout 2m >/dev/null 2>&1; then pass "talosctl health"; else fail "talosctl health (run it by hand to see why)"; fi
fi

BAD=$(kubectl -n kube-system get pods --no-headers 2>/dev/null | grep -v -E 'Running|Completed' | grep -c .)
[ "$BAD" -eq 0 ] && pass "kube-system: all pods Running" || fail "kube-system: $BAD pods not Running"

DEFAULT_SC=$(kubectl get storageclass -o json | jq -r '[.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(" ")')
case "$(echo "$DEFAULT_SC" | wc -w | tr -d ' ')" in
  1) pass "default StorageClass: $DEFAULT_SC" ;;
  0) fail "no default StorageClass (Educates needs one)" ;;
  *) fail "several default StorageClasses: $DEFAULT_SC" ;;
esac

kubectl create namespace "$NS" >/dev/null

###############################################################################
section "Storage"
###############################################################################

if $ALL_SC; then STORAGE_CLASSES=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}'); fi
[ -z "$STORAGE_CLASSES" ] && STORAGE_CLASSES="$DEFAULT_SC"

for SC in $STORAGE_CLASSES; do
  POD="vol-$(echo "$SC" | tr -c 'a-z0-9\n' '-' | cut -c1-40)"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $POD, namespace: $NS}
spec:
  storageClassName: $SC
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: $POD, namespace: $NS}
spec:
$(pod_spec '["pause"]')
      volumeMounts: [{name: data, mountPath: /data}]
    volumes: [{name: data, persistentVolumeClaim: {claimName: $POD}}]
EOF
  START=$SECONDS
  if kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=300s >/dev/null 2>&1; then
    OUT=$(kexec "$NS" "$POD" "echo e2e > /data/probe && cat /data/probe")
    [ "$OUT" = "e2e" ] && pass "$SC: volume created, attached and writable ($((SECONDS - START))s)" || fail "$SC: volume not writable ($OUT)"
  else
    fail "$SC: pod with volume not Ready in 5 minutes"
    kubectl -n "$NS" get events --field-selector "involvedObject.name=$POD" --sort-by=.lastTimestamp 2>/dev/null | tail -n 3 | sed 's/^/       /'
    continue
  fi

  PV=$(kubectl -n "$NS" get pvc "$POD" -o jsonpath='{.spec.volumeName}')
  RECLAIM=$(kubectl get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)
  kubectl -n "$NS" delete pod "$POD" --wait=true >/dev/null 2>&1
  kubectl -n "$NS" delete pvc "$POD" --wait=true >/dev/null 2>&1
  if [ "$RECLAIM" = "Delete" ]; then
    for _ in $(seq 1 24); do kubectl get pv "$PV" >/dev/null 2>&1 || break; sleep 5; done
    kubectl get pv "$PV" >/dev/null 2>&1 && fail "$SC: volume $PV not deleted after its claim" || pass "$SC: volume deleted with its claim (reclaimPolicy Delete)"
  else
    info "$SC: reclaimPolicy $RECLAIM, volume $PV kept by design"
  fi
done

###############################################################################
section "LoadBalancer"
###############################################################################

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: $NS}
spec:
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
$(pod_spec '["netexec", "--http-port=8080"]' | sed 's/^/    /')
---
apiVersion: v1
kind: Service
metadata: {name: web, namespace: $NS}
spec:
  type: LoadBalancer
  selector: {app: web}
  ports: [{port: 80, targetPort: 8080}]
EOF
kubectl -n "$NS" wait --for=condition=Available deploy/web --timeout=300s >/dev/null 2>&1 || fail "test web server not Available"
LB_IP=""
for _ in $(seq 1 24); do
  LB_IP=$(kubectl -n "$NS" get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$LB_IP" ] && break; sleep 5
done
if [ -n "$LB_IP" ]; then
  pass "LoadBalancer IP assigned: $LB_IP"
  OK=""
  for _ in $(seq 1 12); do
    OK=$(curl -s -m 5 "http://$LB_IP/hostname" 2>/dev/null) && [ -n "$OK" ] && break; sleep 5
  done
  [ -n "$OK" ] && pass "reachable from this machine (answered by $OK)" || fail "$LB_IP not reachable from this machine: layer-2 announcements, routing or firewall"
else
  fail "no LoadBalancer IP in 2 minutes: check load_balancer.ip_pools and the Cilium IP pool"
fi

###############################################################################
section "Network from a pod"
###############################################################################

POD_W=$(kubectl -n "$NS" get pods -l app=web -o jsonpath='{.items[0].metadata.name}')
[ "$(kexec "$NS" "$POD_W" "nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo ok")" = "ok" ] \
  && pass "cluster DNS" || fail "cluster DNS from a pod"
[ "$(kexec "$NS" "$POD_W" "wget -q -T 8 -O /dev/null http://web.$NS.svc/hostname && echo ok")" = "ok" ] \
  && pass "pod to Service" || fail "pod to Service"
[ "$(kexec "$NS" "$POD_W" "wget -q -T 10 -O /dev/null https://registry.k8s.io/v2/ 2>&1; nslookup registry.k8s.io >/dev/null 2>&1 && echo ok")" = "ok" ] \
  && pass "external DNS from a pod" || warn "external names do not resolve from pods (fine only with mirrors)"

###############################################################################
section "Educates workshop network (Cilium compatibility)"
###############################################################################

# Replica of what Educates puts in a workshop namespace: its label and its egress policy.
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $NS_EDU
  labels: {training.educates.dev/component: environment}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: educates-network-policy, namespace: $NS_EDU}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [169.254.169.254/32]}}]
---
apiVersion: v1
kind: Pod
metadata: {name: probe, namespace: $NS_EDU}
spec:
$(pod_spec '["pause"]')
EOF
if kubectl get ciliumclusterwidenetworkpolicy educates-allow-in-cluster >/dev/null 2>&1; then
  pass "compatibility policy educates-allow-in-cluster present"
else
  warn "compatibility policy educates-allow-in-cluster missing (educates_workshop_egress_fix = false?)"
fi
if kubectl -n "$NS_EDU" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null 2>&1; then
  sleep 3
  [ "$(kexec "$NS_EDU" probe "nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo ok")" = "ok" ] \
    && pass "workshop pod: cluster DNS" || fail "workshop pod: cluster DNS blocked (Educates policy on Cilium)"
  # Any HTTP answer (200, or 401/403 where anonymous access is off) means the API is reachable.
  [ "$(kexec "$NS_EDU" probe "wget -q -T 8 -O /dev/null --no-check-certificate https://kubernetes.default.svc/version && echo ok || (wget -T 8 -O /dev/null --no-check-certificate https://kubernetes.default.svc/version 2>&1 | grep -q 'HTTP/' && echo ok)")" = "ok" ] \
    && pass "workshop pod: Kubernetes API reachable" || fail "workshop pod: Kubernetes API blocked"
  [ "$(kexec "$NS_EDU" probe "wget -q -T 8 -O /dev/null http://web.$NS.svc/hostname && echo ok")" = "ok" ] \
    && pass "workshop pod: in-cluster Service" || fail "workshop pod: in-cluster Service blocked"
  [ "$(kexec "$NS_EDU" probe "wget -q -T 4 -O /dev/null http://169.254.169.254/ && echo reachable")" = "reachable" ] \
    && fail "workshop pod: metadata IP reachable (should stay blocked)" || pass "workshop pod: metadata IP not reachable"
else
  fail "workshop probe pod not Ready"
fi

###############################################################################
section "Educates"
###############################################################################

if ! kubectl get educatesclusterconfig cluster >/dev/null 2>&1; then
  info "Educates is not installed: skipped"
  $WORKSHOP && fail "--workshop needs Educates installed"
else
  for r in educatesclusterconfig secretsmanager sessionmanager; do
    PHASE=$(kubectl get "$r" cluster -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$PHASE" = "Ready" ] && pass "$r: Ready" || fail "$r: ${PHASE:-missing}"
  done
  ENVOY_IP=$(kubectl -n contour get svc -o json 2>/dev/null | jq -r '[.items[] | select(.spec.type == "LoadBalancer") | .status.loadBalancer.ingress[0].ip // empty] | first // empty')
  [ -n "$ENVOY_IP" ] && pass "ingress (Envoy) LoadBalancer IP: $ENVOY_IP" || fail "ingress (Envoy) has no LoadBalancer IP"
  DOMAIN=$(kubectl get educatesclusterconfig cluster -o jsonpath='{.spec.ingress.domain}')
  RESOLVED=$(getent hosts "e2e-check.$DOMAIN" 2>/dev/null | awk '{print $1}'; true)
  [ -z "$RESOLVED" ] && have dig && RESOLVED=$(dig +short "e2e-check.$DOMAIN" | tail -n 1)
  if [ -z "$RESOLVED" ]; then warn "*.$DOMAIN does not resolve from this machine"
  elif [ "$RESOLVED" = "$ENVOY_IP" ]; then pass "*.$DOMAIN resolves to the ingress IP ($ENVOY_IP)"
  else fail "*.$DOMAIN resolves to $RESOLVED, but the ingress IP is $ENVOY_IP (pin it, see getting-started)"; fi

  if $WORKSHOP; then
    if kubectl get trainingportal "$PORTAL" >/dev/null 2>&1; then
      fail "a training portal named $PORTAL already exists: not touching it"
    else
      CREATED_PORTAL=true
      START=$SECONDS
      educates deploy-workshop -f "$WORKSHOP_URL" --portal "$PORTAL" --initial 1 --overdue 10m >/dev/null 2>&1 \
        && pass "sample workshop deployed in portal $PORTAL" || fail "educates deploy-workshop failed"
      SPOD=""
      for _ in $(seq 1 72); do
        SPOD=$(kubectl -n "$PORTAL-w01" get pods -o json 2>/dev/null | jq -r '[.items[] | select(any(.spec.containers[]; .name == "workshop")) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.name] | first // empty')
        [ -n "$SPOD" ] && break; sleep 10
      done
      if [ -z "$SPOD" ]; then
        fail "no workshop session Ready in 12 minutes"
      else
        pass "workshop session pod Ready ($((SECONDS - START))s, includes the image pull on a new node)"
        T() { kubectl -n "$PORTAL-w01" exec "$SPOD" -c workshop -- sh -c "$1" 2>&1 | tail -n 1; }
        [ "$(T "getent hosts training-portal.$PORTAL-ui >/dev/null && echo ok")" = "ok" ] \
          && pass "session: resolves the portal (needed for login)" || fail "session: cannot resolve the portal"
        [ "$(T "kubectl get pods -o name >/dev/null && echo ok")" = "ok" ] \
          && pass "session: kubectl reaches the Kubernetes API" || fail "session: kubectl cannot reach the API"
        PURL=$(kubectl get trainingportal "$PORTAL" -o jsonpath='{.status.educates.url}')
        SURL=$(kubectl get workshopsessions -o json | jq -r --arg p "$PORTAL-w01" '[.items[] | select(.spec.environment.name == $p) | .status.educates.url // empty] | first // empty')
        for U in "$PURL" "$SURL"; do
          [ -z "$U" ] && continue
          # Contour needs a few seconds to program a new route: 503 until then.
          for _ in $(seq 1 24); do
            CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 15 $CURL_CA "$U/")
            case "$CODE" in 2*|3*) break ;; esac
            sleep 5
          done
          case "$CODE" in
            2*|3*) pass "HTTPS $U (HTTP $CODE, certificate trusted)" ;;
            000) fail "HTTPS $U: no answer or untrusted certificate (try --ca-file)" ;;
            *) fail "HTTPS $U: HTTP $CODE" ;;
          esac
        done
      fi
    fi
  fi
fi

echo
echo "Failures: $FAILS, warnings: $WARNS."
[ "$FAILS" -eq 0 ]
