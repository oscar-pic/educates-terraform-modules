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
resource "kubectl_manifest" "educates_installer_namespace" {
  yaml_body = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: educates-installer"
  depends_on = [null_resource.wait_for_k8s]
}

resource "kubernetes_secret_v1" "educates_tls" {
  metadata {
    name      = "educates-tls"
    namespace = "educates-installer"
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.educates_cert.cert_pem
    "tls.key" = tls_private_key.educates_key.private_key_pem
  }
  depends_on = [kubectl_manifest.educates_installer_namespace]
}

resource "kubernetes_secret_v1" "educates_config" {
  metadata {
    name      = "educates-installer-config"
    namespace = "educates-installer"
  }
# We use 'config.yaml' inside the secret to match the imgpkg bundle structure
  data = {
    "config.yaml" = <<-YAML
      cluster:
        domain: ${var.educates_portal_domain}
      ingress:
        type: traefik
      storage:
        type: local-path
      tls:
        secretName: educates-tls
    YAML
  }
  depends_on = [kubectl_manifest.educates_installer_namespace]
}

# --- THE EDUCATES INSTALLER APP (The Bridge) ---
resource "kubectl_manifest" "educates_installer_app" {
  yaml_body = <<-YAML
    apiVersion: kappctrl.k14s.io/v1alpha1
    kind: App
    metadata:
      name: installer.educates.dev
      namespace: educates-installer
    spec:
      serviceAccountName: educates-installer
      syncPeriod: 87600h
      fetch:
      - imgpkgBundle:
          image: ghcr.io/educates/educates-installer:${var.educates_version}
        path: bundle
      template:
      - ytt:
          valuesFrom:
          - secretRef:
              name: educates-installer-config
          paths:
          - bundle/config/kapp
          - bundle/config/ytt
      deploy:
      - kapp:
          rawOptions:
          - --app-changes-max-to-keep=0
  YAML

  depends_on = [
    kubectl_manifest.kapp_controller, 
    kubernetes_secret_v1.educates_config,
    kubernetes_secret_v1.educates_tls
  ]
}
