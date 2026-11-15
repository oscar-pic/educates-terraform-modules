###############################################################################
# Compatibility with Educates on Cilium (temporary, until Educates handles it).
#
# Educates puts a NetworkPolicy in every workshop namespace meaning "allow all
# egress except the cloud metadata IP" (ipBlock 0.0.0.0/0 except
# 169.254.169.254/32). Cilium applies ipBlock only to traffic leaving the
# cluster, so that policy also cuts workshop pods off from cluster DNS, services
# and the Kubernetes API: sessions fail to start or to log in. Educates 4 cannot
# switch the policy off (an empty blockedCidrs list falls back to the defaults).
#
# Cilium policies add up: this one gives the pods of Educates workshop namespaces
# in-cluster egress, so the result is what Educates intends (everything allowed
# except the metadata IP). It only selects namespaces labelled by Educates.
# It repeats the Educates rule for traffic leaving the cluster: a policy that
# selects a pod denies the egress it does not allow, so on its own (a labelled
# namespace without the Educates policy) it still means the same.
###############################################################################

resource "kubectl_manifest" "educates_workshop_egress" {
  count = var.educates_workshop_egress_fix ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "educates-allow-in-cluster"
      annotations = {
        description = "Educates workshop NetworkPolicy (ipBlock egress) blocks in-cluster traffic on Cilium: allow it for Educates workshop namespaces."
      }
    }
    spec = {
      endpointSelector = {
        matchExpressions = [{
          key      = "io.cilium.k8s.namespace.labels.training.educates.dev/component"
          operator = "In"
          values   = ["environment", "session"]
        }]
      }
      egress = [
        { toEntities = ["cluster", "kube-apiserver"] },
        { toCIDRSet = [{ cidr = "0.0.0.0/0", except = ["169.254.169.254/32"] }] },
      ]
    }
  })

  depends_on = [data.talos_cluster_health.this]
}
