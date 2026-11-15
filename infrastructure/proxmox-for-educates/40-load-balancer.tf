# LoadBalancer IPs for Services (the Educates ingress or gateway, and any other).
# Cilium answers ARP for them from one node at a time (L2 announcements).

resource "kubectl_manifest" "lb_ip_pool" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "default" }
    spec = {
      blocks = [
        for p in var.load_balancer.ip_pools : (
          strcontains(p, "-")
          ? { start = trimspace(split("-", p)[0]), stop = trimspace(split("-", p)[1]) }
          : { cidr = p }
        )
      ]
    }
  })

  depends_on = [data.talos_cluster_health.this]
}

resource "kubectl_manifest" "l2_announcement_policy" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "default" }
    spec = {
      interfaces      = coalesce(var.load_balancer.interfaces, ["^${var.network.interface}$"])
      loadBalancerIPs = true
      externalIPs     = false
    }
  })

  depends_on = [data.talos_cluster_health.this]
}
