# Terraform module to install Educates locally (via CLI)

Terraform module for deploying Educates 3.x on a remote VM using the `educates` CLI. Unlike the `platform/educates` module which deploys via kapp-controller and the kubectl provider against an existing Kubernetes API, this module connects to a VM via SSH and runs the `educates create-cluster` command to create a Kind cluster with Educates pre-installed.

## What this module does

1. **Waits for VM readiness** — polls via SSH until the startup script has finished installing Docker
2. **Installs the educates CLI** — downloads the binary from GitHub releases for the specified version
3. **Creates the cluster** — runs `educates create-cluster --config CONFIG.yaml` which creates a Kind cluster and deploys Educates
4. **Configures credentials** (post-creation) — creates Kubernetes secrets with GCP service account keys for cert-manager and external-dns, and patches the ClusterIssuer for DNS-01 ACME challenges

## Why a separate module?

The existing `platform/educates` module deploys via `kubectl_manifest` resources against an existing Kubernetes API. In this scenario, the Kubernetes cluster doesn't exist yet — it's created by the `educates` CLI on the VM. This requires SSH-based provisioning rather than kubectl-based resource management.

## Credential handling (hybrid approach)

Since Kind clusters don't support GKE Workload Identity, cert-manager and external-dns need explicit GCP service account credentials:

- **During cluster creation**: The educates config uses `provider: custom` with external-dns configured to mount a SA key secret as a volume
- **After cluster creation**: Terraform creates the actual Kubernetes secrets containing the SA key JSON files and patches the cert-manager ClusterIssuer to reference them

This hybrid approach is necessary because the Kind cluster must exist before secrets can be created, but the educates config needs to reference those secrets during deployment.

### Suggested improvements to Educates Training Platform

The following upstream changes would simplify this module:

1. Add GCP SA key credential support to the certs package (matching AWS `acme.aws.credentials`)
2. Add GCP SA key credential support to external-dns (the fields are commented out in the schema)
3. Remove the hardcoded GKE `nodeSelector` from the external-dns GCP overlay
4. Support pre-provisioning secrets in the `educates create-cluster` config

See the plan file for full details on each suggestion.

## Configuration

This module is typically used via the `root-modules/local-educates-on-gce` root module, not standalone.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_null"></a> [null](#requirement\_null) | ~> 3.2 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_null"></a> [null](#provider\_null) | ~> 3.2 |

## Resources

| Name | Type |
|------|------|
| [null_resource.wait_for_startup](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.install_educates](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |
| [null_resource.configure_credentials](https://registry.terraform.io/providers/hashicorp/null/latest/docs/resources/resource) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_educates_version"></a> [educates\_version](#input\_educates\_version) | Version of the educates CLI to install | `string` | `"3.3.2"` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name for the Kind cluster | `string` | n/a | yes |
| <a name="input_wildcard_domain"></a> [wildcard\_domain](#input\_wildcard\_domain) | Wildcard domain for educates ingress | `string` | n/a | yes |
| <a name="input_ssh_connection"></a> [ssh\_connection](#input\_ssh\_connection) | SSH connection details to the VM | <pre>object({<br/>    host        = string<br/>    user        = string<br/>    private_key = string<br/>  })</pre> | n/a | yes |
| <a name="input_certmanager_sa_key"></a> [certmanager\_sa\_key](#input\_certmanager\_sa\_key) | Base64-encoded GCP service account key JSON for cert-manager | `string` | n/a | yes |
| <a name="input_externaldns_sa_key"></a> [externaldns\_sa\_key](#input\_externaldns\_sa\_key) | Base64-encoded GCP service account key JSON for external-dns | `string` | n/a | yes |
| <a name="input_gcp_project"></a> [gcp\_project](#input\_gcp\_project) | GCP project ID | `string` | n/a | yes |
| <a name="input_dns_zone"></a> [dns\_zone](#input\_dns\_zone) | Cloud DNS zone domain | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_educates"></a> [educates](#output\_educates) | Educates deployment details (version, cluster name, domain) |
