#!/usr/bin/env bash
# Inventory of what an Educates install created at cluster scope, for the cluster owner's review.
#
# `educates admin platform render` shows only the operator's chart values and the platform
# resources: Kyverno, Contour and their webhooks, CRDs and roles are installed later by the
# operator itself. This script lists what is really there, right after the install and before
# any workshop is opened (docs/bring-your-own-cluster.md).
#
#   scripts/educates-inventory.sh --snapshot crds.before   # BEFORE installing: state of every CRD
#   educates admin platform deploy --config educates.yaml
#   scripts/educates-inventory.sh --before crds.before > inventory.txt
#
# Objects count as created by the install when they are newer than the educates-installer
# namespace. Namespaces older than it are the cluster's own: the script flags any admission
# webhook that fails closed, intercepts more than Kyverno's own resource types, and applies to
# one of them. Needs kubectl and jq, and a kubeconfig that can read cluster-scoped objects.

set -uo pipefail

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
SNAPSHOT=""; BEFORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) SNAPSHOT="${2:?}"; shift 2 ;;
    --before) BEFORE="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

for t in kubectl jq; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 1; }; done
K=kubectl

crd_state() { $K get crd -o json | jq -r '.items[] | "\(.metadata.name) \(.metadata.resourceVersion) \(.metadata.generation)"' | sort; }

if [ -n "$SNAPSHOT" ]; then
  crd_state > "$SNAPSHOT" && echo "$(wc -l < "$SNAPSHOT" | tr -d ' ') CRDs saved to $SNAPSHOT"
  exit 0
fi

T0=$($K get ns educates-installer -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
[ -n "$T0" ] || { echo "namespace educates-installer not found: is Educates installed?" >&2; exit 1; }
# The cluster's own namespaces: older than the install.
OWN_NS=$($K get ns -o json | jq -r --arg t "$T0" '.items[] | select(.metadata.creationTimestamp < $t) | .metadata.name' | tr '\n' ' ')
NEW_NS=$($K get ns -o json | jq -r --arg t "$T0" '.items[] | select(.metadata.creationTimestamp >= $t) | .metadata.name')

new() { # cluster-scoped objects of a kind created by the install
  $K get "$1" -o json 2>/dev/null | jq -r --arg t "$T0" '.items[] | select(.metadata.creationTimestamp >= $t) | .metadata.name'
}
sel() { # label selector (JSON) -> kubectl -l syntax; empty = every namespace
  jq -r '[ (.matchLabels // {} | to_entries[] | "\(.key)=\(.value)"),
           (.matchExpressions // [] | .[] |
             if .operator == "In" then "\(.key) in (\(.values | join(",")))"
             elif .operator == "NotIn" then "\(.key) notin (\(.values | join(",")))"
             elif .operator == "Exists" then .key
             else "!\(.key)" end) ] | join(",")'
}

ATTENTION=0
echo "Educates inventory, cluster $($K config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "Generated $(date -u +%FT%TZ). Created by the install: objects newer than $T0 (namespace educates-installer)."
echo

echo "== 1. Workloads"
for n in $NEW_NS; do
  $K -n "$n" get deployments,statefulsets,daemonsets -o json | jq -r --arg n "$n" '.items[]
    | if .kind == "DaemonSet" then [.status.desiredNumberScheduled // 0, .status.numberReady // 0]
      else [.spec.replicas // 1, .status.readyReplicas // 0] end as [$want, $ready]
    | "   \(if $ready < $want then "NOT READY" else "ready    " end) \($n)/\(.kind)/\(.metadata.name) \($ready)/\($want)"'
done
NOTREADY=$(for n in $NEW_NS; do $K -n "$n" get deployments,statefulsets,daemonsets -o json | jq -r '.items[]
  | if .kind == "DaemonSet" then [.status.desiredNumberScheduled // 0, .status.numberReady // 0]
    else [.spec.replicas // 1, .status.readyReplicas // 0] end as [$w, $r] | select($r < $w) | .metadata.name'; done | wc -l | tr -d ' ')
[ "$NOTREADY" = 0 ] || { ATTENTION=$((ATTENTION + NOTREADY)); echo "   >>> $NOTREADY workload(s) not ready: see their events (kubectl get events -n <namespace>)"; }
echo

echo "== 2. Admission webhooks created by the install"
echo "   Namespaces matched: those a namespaced request must be in for the webhook to be called."
for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
  for cfg in $(new $kind); do
    echo
    echo "-- $kind/$cfg"
    while read -r wh; do
      fp=$(jq -r '.failurePolicy' <<<"$wh")
      nss=$(jq -c '.namespaceSelector // {}' <<<"$wh")
      rules=$(jq -r '[.rules[]? | "\(.apiGroups | map(if . == "" then "core" else . end) | join(","))/\(.resources | join(","))[\(.operations | join(","))]"] | join("; ")' <<<"$wh")
      # Kyverno validates its own resource types cluster-wide: those calls concern no other workload.
      other=$(jq -r '[.rules[]? | .apiGroups[] | select(test("(^|\\.)kyverno\\.io$") | not)] | length' <<<"$wh")
      s=$(sel <<<"$nss")
      hit=$($K get ns ${s:+-l "$s"} -o name 2>/dev/null | sed 's|namespace/||' | tr '\n' ' ')
      own=""; for n in $OWN_NS; do [[ " $hit " == *" $n "* ]] && own+="$n "; done
      echo "   webhook $(jq -r .name <<<"$wh")"
      echo "     failurePolicy: $fp"
      echo "     namespaceSelector: $nss"
      echo "     objectSelector: $(jq -c '.objectSelector // {}' <<<"$wh")"
      echo "     rules: ${rules:-none}"
      echo "     namespaces matched now: ${hit:-none}"
      if [ "$fp" = "Fail" ] && [ -n "$own" ] && [ -n "$rules" ]; then
        if [ "$other" != 0 ]; then
          echo "     >>> ATTENTION: fails closed on the cluster's own namespaces: $own"; ATTENTION=$((ATTENTION + 1))
        else
          echo "     note: fails closed in every namespace, but only for Kyverno's own resource types"
        fi
      fi
    done < <($K get "$kind" "$cfg" -o json | jq -c '.webhooks[]?')   # not a pipe: ATTENTION must survive
  done
done
echo

echo "== 3. Policies"
echo "-- validatingpolicies.policies.kyverno.io"
$K get validatingpolicies.policies.kyverno.io -o json 2>/dev/null | jq -r '.items[] | "   \(.metadata.name): actions=\(.spec.validationActions | join(",")) namespaceSelector=\(.spec.matchConstraints.namespaceSelector // {} | tojson)"'
for r in clusterpolicies.kyverno.io mutatingpolicies.policies.kyverno.io generatingpolicies.policies.kyverno.io imagevalidatingpolicies.policies.kyverno.io; do
  echo "-- $r: $($K get "$r" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
done
echo "-- ValidatingAdmissionPolicies created: $(new validatingadmissionpolicies | wc -l | tr -d ' ')"
echo

echo "== 4. CustomResourceDefinitions"
echo "-- created:"
new customresourcedefinitions | sed 's/^/   /'
if [ -n "$BEFORE" ]; then
  echo "-- CRDs that existed before the install and changed since (from $BEFORE):"
  CHANGED=$(join <(sort "$BEFORE") <(crd_state) | awk '$2 != $4 || $3 != $5 {print "   " $1}')
  if [ -z "$CHANGED" ]; then echo "   none"; else echo "$CHANGED"; echo "   >>> ATTENTION: the install changed CRDs it does not own"; ATTENTION=$((ATTENTION + 1)); fi
else
  echo "-- (run with --before <snapshot> to check that the CRDs that already existed are untouched)"
fi
echo

echo "== 5. ClusterRoles and ClusterRoleBindings created"
new clusterroles | sed 's/^/   ClusterRole /'
$K get clusterrolebindings -o json | jq -r --arg t "$T0" '.items[] | select(.metadata.creationTimestamp >= $t)
  | "   ClusterRoleBinding \(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name) for \([.subjects[]? | "\(.kind):\(.namespace // "-")/\(.name)"] | join(", "))"'
echo

echo "== 6. Other cluster-scoped objects"
$K get ingressclass -o json | jq -r '.items[] | "   IngressClass \(.metadata.name): controller=\(.spec.controller) default=\(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "false")"'
echo "   ClusterIssuers created: $(new clusterissuers.cert-manager.io | wc -l | tr -d ' ')"
echo "   APIServices created: $(new apiservices | tr '\n' ' ')"
echo

echo "== 7. Ingress (Envoy) Service"
$K -n contour get service contour-envoy -o json 2>/dev/null | jq -r '"   type=\(.spec.type) IP=\([.status.loadBalancer.ingress[]?.ip] | join(",")) ports=\([.spec.ports[] | "\(.port)"] | join(","))", (.metadata.annotations // {} | to_entries[] | "   annotation \(.key)=\(.value)")' \
  || echo "   contour/contour-envoy not found"
echo

echo "== 8. Namespaces created"
for n in $NEW_NS; do echo "   $n"; done
echo

echo "== 9. Images (as requested, and the digest pulled)"
for n in $NEW_NS; do
  $K -n "$n" get pods -o json | jq -r '.items[].status | ((.containerStatuses // []) + (.initContainerStatuses // []))[] | "\(.image)\t\(.imageID)"'
done | sort -u | awk -F'\t' '{split($1, a, "/"); reg = (a[1] ~ /[.:]/ ? a[1] : "docker.io"); printf "   %-18s %s\n   %-18s %s\n", reg, $1, "", $2}'
echo "   (with registry mirrors, pods still show the original registry: check the mirror's own logs)"
echo

if [ "$ATTENTION" = 0 ]; then echo "Summary: nothing flagged."; else echo "Summary: $ATTENTION item(s) flagged (ATTENTION, NOT READY)."; fi
