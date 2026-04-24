# --- TLS GENERATION ---
resource "tls_private_key" "educates_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "educates_cert" {
  private_key_pem = tls_private_key.educates_key.private_key_pem
  subject {
    common_name  = "*.${var.educates_portal_domain}"
    organization = "Educates Lab"
  }
  validity_period_hours = 8760
  allowed_uses = ["key_encipherment", "digital_signature", "server_auth"]
}

# --- ENGINE: KAPP-CONTROLLER ---
data "http" "kapp_controller_release" {
  url = "https://github.com/carvel-dev/kapp-controller/releases/download/${var.kapp_controller_version}/release.yml" 
}

data "kubectl_file_documents" "kapp_controller" {
  content = data.http.kapp_controller_release.response_body 
}

resource "kubectl_manifest" "kapp_controller" {
  for_each  = data.kubectl_file_documents.kapp_controller.manifests
  yaml_body = each.value
  depends_on = [null_resource.wait_for_k8s]
}

# --- EDUCATES RESOURCES ---

# 1. El Namespace (La base de todo)
resource "kubernetes_namespace_v1" "educates_installer" {
  metadata {
    name = "educates-installer"
  }
  depends_on = [null_resource.wait_for_k8s]
}

# 2. Secreto TLS
resource "kubernetes_secret_v1" "educates_tls" {
  metadata {
    name      = "educates-tls"
    namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.educates_cert.cert_pem
    "tls.key" = tls_private_key.educates_key.private_key_pem
  }
}

# 3. Configuración del Instalador
resource "kubernetes_secret_v1" "educates_config" {
  metadata {
    name      = "educates-installer-config"
    namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
  }
  data = {
    "values.yml" = <<-EOT
      #!data/values
      ---
      clusterInfrastructure:
        provider: custom
      clusterPackages:
        educates:
          enabled: true
          settings:
            imageRegistry:
              host: ghcr.io
              namespace: educates
        kyverno:
          enabled: true
      clusterIngress:
        domain: ${var.educates_portal_domain} 
        class: traefik
      clusterStorage:
        class: local-path
      clusterRuntime:
        class: default
    EOT
  }
}

# 4. ServiceAccount para el Instalador
resource "kubernetes_service_account_v1" "educates_installer" {
  metadata {
    name      = "educates-installer"
    namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
  }
}

# 5. Permisos de Admin
resource "kubernetes_cluster_role_binding_v1" "educates_installer_admin" {
  metadata {
    name = "educates-installer-admin-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.educates_installer.metadata[0].name
    namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
  }
}

# 6. La Aplicación del Instalador (Kapp App)
resource "kubectl_manifest" "educates_installer_app" {
  yaml_body = <<-YAML
    apiVersion: kappctrl.k14s.io/v1alpha1
    kind: App
    metadata:
      name: installer.educates.dev
      namespace: educates-installer
    spec:
      serviceAccountName: educates-installer
      fetch:
      - imgpkgBundle:
          image: ghcr.io/educates/educates-installer:${var.educates_version}
      template:
      - ytt:
          paths:
          - config
          valuesFrom:
          - secretRef:
              name: educates-installer-config
      deploy:
      - kapp:
          rawOptions:
          - --app-changes-max-to-keep=5
          # CRITICAL: Force ownership of existing resources to overwrite default configurations
          - --dangerous-override-ownership-of-existing-resources=true
          - --wait-check-interval=5s
  YAML
  
  # Depende del Secreto y del ServiceAccount con permisos
  depends_on = [
    kubernetes_secret_v1.educates_config,
    kubernetes_cluster_role_binding_v1.educates_installer_admin
  ]
}

# 7. Pausa para que el Operador registre los CRDs
resource "time_sleep" "wait_for_crds" {
  create_duration = "2m"
  depends_on      = [kubectl_manifest.educates_installer_app]
}

# 8. El Portal de Entrenamiento (El destino final)
resource "kubectl_manifest" "training_portal" {
  yaml_body = yamlencode({
    apiVersion = "training.educates.dev/v1beta1"
    kind       = "TrainingPortal"
    metadata = {
      name = "educates"
    }
    spec = {
      portal = {
        title = "My Proxmox Lab"
        
        ingress = {
          hostname = "educates.${var.educates_portal_domain}"
          tlsCertificateRef = {
            name = "educates-tls-certs"
          }
        }

        cookies = {
          domain = var.educates_portal_domain
        }

        registration = {
          type = "anonymous"
        }

        credentials = {
          robot = {
            username = "robot"
            password = "educates-robot-password"
          }
        }

        clients = {
          robot = {
            id = "robot"
          }
        }
      }
      workshops = []
    }
  })

  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true

  depends_on = [
    time_sleep.wait_for_crds,
    kubectl_manifest.educates_installer_app
  ]
}