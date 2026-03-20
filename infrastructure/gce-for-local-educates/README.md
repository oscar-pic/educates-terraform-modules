# GCE Terraform module for Local Educates

This module will create a Google Compute Engine (GCE) instance suitable to run a local Educates cluster (Kind-based) via the `educates` CLI.

Unlike the GKE module which creates a managed Kubernetes cluster, this module creates a single VM with Docker pre-installed, a static external IP, DNS wildcard records, and GCP service accounts with exported JSON keys for cert-manager and external-dns (since Kind clusters don't support GKE Workload Identity).

## What this module creates

- A VPC with a single subnet and firewall rules (HTTP, HTTPS, SSH)
- A static external IP address
- A GCE instance with Docker pre-installed via startup script
- A wildcard DNS A record (`*.{cluster_name}.{TLD}`) pointing to the static IP
- GCP service accounts for cert-manager and external-dns with `roles/dns.admin`
- Service account key exports (JSON) for use inside the Kind cluster
- An auto-generated SSH keypair for VM access

## Configuration

Create a file named `main.tfvars` and place all the required configuration there.

### Required variables

| Variable | Description |
|----------|-------------|
| `project_id` | GCP project ID |
| `region` | GCP region for the instance |
| `cluster_name` | Name used for resources and DNS records |
| `dns_zone_name` | Name of an existing Cloud DNS managed zone |
| `TLD` | Top-level domain (e.g. `educates.example.com`) |

### Optional variables

| Variable | Default | Description |
|----------|---------|-------------|
| `zone` | `"{region}-a"` | GCP zone for the instance |
| `machine_type` | `"e2-standard-4"` | GCE machine type |
| `disk_size_gb` | `100` | Boot disk size in GB |
| `disk_type` | `"pd-balanced"` | Boot disk type |
| `image_family` | `"ubuntu-2204-lts"` | OS image family |
| `image_project` | `"ubuntu-os-cloud"` | OS image project |
| `ssh_user` | `"educates"` | SSH username |

## How to run

### Create

```
terraform apply -var-file main.tfvars
```

### Destroy

```
terraform destroy -var-file main.tfvars
```

## Differences from GKE module

| Aspect | GKE module | GCE module |
|--------|-----------|-----------|
| Kubernetes | Managed GKE cluster | Kind cluster on VM (created separately) |
| Networking | VPC with pod/service CIDRs | Simple VPC, single subnet |
| cert-manager/external-dns auth | Workload Identity bindings | Service account key JSON export |
| DNS | Managed by external-dns | Wildcard A record created by Terraform |
| Output | Kubernetes API connection info | SSH connection info + SA keys |

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_google"></a> [google](#requirement\_google) | 6.47.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | 4.1.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | 6.47.0 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | 4.1.0 |

## Resources

| Name | Type |
|------|------|
| [google_compute_address.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_address) | resource |
| [google_compute_firewall.allow_http](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_https](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_ssh](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_firewall) | resource |
| [google_compute_instance.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_instance) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_network) | resource |
| [google_compute_subnetwork.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/compute_subnetwork) | resource |
| [google_dns_record_set.wildcard](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/dns_record_set) | resource |
| [google_project_iam_binding.cert-manager-and-external-dns-as-dns-admin](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/project_iam_binding) | resource |
| [google_service_account.cert-manager-gsa](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/service_account) | resource |
| [google_service_account.external-dns-gsa](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/service_account) | resource |
| [google_service_account_key.cert-manager](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/service_account_key) | resource |
| [google_service_account_key.external-dns](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/resources/service_account_key) | resource |
| [tls_private_key.ssh](https://registry.terraform.io/providers/hashicorp/tls/4.1.0/docs/resources/private_key) | resource |
| [google_compute_image.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/data-sources/compute_image) | data source |
| [google_dns_managed_zone.this](https://registry.terraform.io/providers/hashicorp/google/6.47.0/docs/data-sources/dns_managed_zone) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name used for resources and DNS records | `string` | n/a | yes |
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Boot disk size in GB | `number` | `100` | no |
| <a name="input_disk_type"></a> [disk\_type](#input\_disk\_type) | Boot disk type | `string` | `"pd-balanced"` | no |
| <a name="input_dns_zone_name"></a> [dns\_zone\_name](#input\_dns\_zone\_name) | Name of an existing Cloud DNS managed zone | `string` | n/a | yes |
| <a name="input_image_family"></a> [image\_family](#input\_image\_family) | OS image family for the compute instance | `string` | `"ubuntu-2204-lts"` | no |
| <a name="input_image_project"></a> [image\_project](#input\_image\_project) | GCP project hosting the OS image | `string` | `"ubuntu-os-cloud"` | no |
| <a name="input_machine_type"></a> [machine\_type](#input\_machine\_type) | GCE machine type for the compute instance | `string` | `"e2-standard-4"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region where this instance will be created | `string` | n/a | yes |
| <a name="input_ssh_user"></a> [ssh\_user](#input\_ssh\_user) | SSH username for the compute instance | `string` | `"educates"` | no |
| <a name="input_TLD"></a> [TLD](#input\_TLD) | Top-level domain for DNS records (e.g. educates.example.com) | `string` | n/a | yes |
| <a name="input_zone"></a> [zone](#input\_zone) | GCP zone for the compute instance. Defaults to first zone in the region | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gce"></a> [gce](#output\_gce) | GCE instance details including SA keys (sensitive) |
| <a name="output_ssh_connection"></a> [ssh\_connection](#output\_ssh\_connection) | SSH connection details for the VM (sensitive) |
