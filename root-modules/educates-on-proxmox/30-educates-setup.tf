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

  wait_for_rollout = true  # Wait for pod to be Ready to continue
  force_new        = true   # If there are conflicts, recreate the resource forcefully
}

# --- EDUCATES RESOURCES ---

# 1. El Namespace (La base de todo)
resource "kubernetes_namespace_v1" "educates_installer" {
  metadata {
    name = "educates-installer"
  }
  depends_on = [null_resource.wait_for_k8s]
}

resource "null_resource" "wait_for_educates_ui_ns" {
  provisioner "local-exec" {
    command = "bash ${path.module}/wait_for_educates_ui_ns.sh ${path.module}/k8s_config.yaml educates-ui"
  }
  depends_on = [kubectl_manifest.training_portal]
}

# 2. Leemos el namespace una vez que sabemos que existe
data "kubernetes_namespace_v1" "educates_ui" {
#resource "kubernetes_namespace_v1" "educates_ui" {
  metadata {
    name = "educates-ui"
  }
  depends_on = [null_resource.wait_for_educates_ui_ns]
}

# 2. Secreto TLS
resource "kubernetes_secret_v1" "educates_tls" {
  metadata {
    name      = "educates-wildcard-certs"
    #namespace = "educates-ui"
    namespace = data.kubernetes_namespace_v1.educates_ui.metadata[0].name
    #namespace = resource.kubernetes_namespace_v1.educates_ui.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.educates_cert.cert_pem
    "tls.key" = tls_private_key.educates_key.private_key_pem
  }
}

# 3. Configuración del Instalador
resource "kubernetes_secret_v1" "educates_installer_config" {
  metadata {
    name      = "educates-installer-config"
    namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
  }
  data = {
    "values.yaml" = <<-EOT
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
            # Inyectamos el dominio aquí para que el session-manager 
            # no use el valor por defecto de la imagen
            # sessionManager:
            #   enabled: true
              # env:
              #   - name: INGRESS_DOMAIN
              #     value: ${var.educates_portal_domain}
              #   - name: INGRESS_PROTOCOL
              #     value: https
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
# resource "kubernetes_secret_v1" "educates_installer_config" {
#   metadata {
#     name      = "educates-installer-config"
#     namespace = kubernetes_namespace_v1.educates_installer.metadata[0].name
#   }
#   data = {
#     "values.yml" = <<-EOT
#       #!data/values
#       ---
#       clusterInfrastructure:
#         provider: custom
#       clusterPackages:
#         educates:
#           enabled: true
#           settings:
#             imageRegistry:
#               host: ghcr.io
#               namespace: educates
#         kyverno:
#           enabled: true
#       clusterIngress:
#         domain: ${var.educates_portal_domain} 
#         class: traefik
#       clusterStorage:
#         class: local-path
#       clusterRuntime:
#         class: default
#     EOT
#   }
# }

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

resource "null_resource" "wait_for_kapp_controller" {
  depends_on = [kubectl_manifest.kapp_controller] # O el recurso que instala Carvel

  provisioner "local-exec" {
    command = "bash ${path.module}/wait_for_kapp.sh ${path.module}/k8s_config.yaml"
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
    null_resource.wait_for_kapp_controller,
    kubernetes_secret_v1.educates_installer_config,
    kubernetes_cluster_role_binding_v1.educates_installer_admin
  ]
}

# 7. Pausa para que el Operador registre los CRDs
# resource "time_sleep" "wait_for_educates_crds" {
#   create_duration = "5m"
#   depends_on      = [kubectl_manifest.educates_installer_app]
# }

resource "null_resource" "wait_for_educates_crds" {
  # IMPORTANTE: Depende del instalador que lanza Carvel
  depends_on = [kubectl_manifest.educates_installer_app] 

  provisioner "local-exec" {
    command = "bash ${path.module}/wait_for_educates_crds.sh ${path.module}/k8s_config.yaml"
  }
}

# 8. El Portal de Entrenamiento (El destino final)
# resource "kubectl_manifest" "training_portal" {
#   yaml_body = yamlencode({
#     apiVersion = "training.educates.dev/v1beta1"
#     kind       = "TrainingPortal"
#     metadata = {
#       name      = "educates"
#       namespace = "educates-ui"
#     }
#     spec = {
#       portal = {
#         title = "My Proxmox Lab"
        
#         ingress = {
#           hostname = "${var.educates_portal_hostname}.${var.educates_portal_domain}"
#           tlsCertificateRef = {
#             #name = kubernetes_secret_v1.educates_tls.metadata[0].name
#             name = "educates-wildcard-certs"
#           }
#         }

#         cookies = {
#           domain = var.educates_portal_domain
#         }

#         registration = {
#           type = "anonymous"
#         }

#         credentials = {
#           robot = {
#             username = "robot"
#             password = "educates-robot-password"
#           }
#         }

#         clients = {
#           robot = {
#             id = "robot"
#           }
#         }
#       }
#       workshops = []
#     }
#   })

#   server_side_apply = true
#   force_conflicts   = true
#   wait_for_rollout  = true

#   depends_on = [
#     null_resource.wait_for_educates_crds,
#     kubernetes_secret_v1.educates_tls,
#     kubernetes_namespace_v1.educates_ui
#     #kubectl_manifest.educates_installer_app
#   ]
# }

resource "kubectl_manifest" "training_portal" {
  yaml_body = yamlencode({
    apiVersion = "training.educates.dev/v1beta1"
    kind       = "TrainingPortal"
    metadata = {
      name = "educates"
      # Quitamos el namespace de aquí para evitar que Terraform intente 
      # validarlo antes de que el operador lo cree.
    }
    spec = {
      portal = {
        title = "My Proxmox Lab"
        
        ingress = {
          # Usamos el FQDN completo como tenías en la versión que funcionaba
          hostname = "${var.educates_portal_hostname}.${var.educates_portal_domain}"
          tlsCertificateRef = {
            name = "educates-wildcard-certs"
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
  
  # Importante: wait_for_rollout false para que no bloquee 
  # la creación del secreto TLS que viene después
  wait_for_rollout  = false

  depends_on = [
    null_resource.wait_for_educates_crds
  ]
}