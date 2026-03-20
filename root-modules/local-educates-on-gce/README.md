# Local Educates on GCE

Reference root module that deploys Educates on a Google Compute Engine VM running a Kind cluster. This is the GCE equivalent of the `educates-on-gke` and `educates-on-eks` root modules, but instead of using a managed Kubernetes service, it creates a single VM and uses the `educates` CLI to create a local Kind cluster.

## Architecture

```
                    ┌─────────────────────────────────┐
                    │   GCE VM (Ubuntu + Docker)      │
                    │                                 │
                    │   ┌─────────────────────────┐   │
                    │   │   Kind Cluster           │   │
  *.cluster.TLD ──► │   │                         │   │
  (static IP)       │   │   Educates Platform     │   │
                    │   │   Contour (ports 80/443) │   │
                    │   │   cert-manager           │   │
                    │   │   external-dns           │   │
                    │   └─────────────────────────┘   │
                    └─────────────────────────────────┘
```

## What this module creates

1. **Infrastructure** (`infrastructure/gce-for-local-educates`):
   - GCE VM with Docker, static IP, VPC, firewall rules
   - Wildcard DNS record in an existing Cloud DNS zone
   - GCP service accounts with JSON key export for cert-manager and external-dns

2. **Platform** (`platform/educates-local`):
   - Installs the `educates` CLI on the VM
   - Runs `educates create-cluster` to create a Kind cluster with Educates
   - Configures cert-manager and external-dns with GCP SA key credentials

## Prerequisites

- A GCP project with Compute Engine and Cloud DNS APIs enabled
- An existing Cloud DNS managed zone for your domain
- Terraform >= 1.5.0

## Configuration

Create a file named `main.tfvars`:

```hcl
project_id      = "my-gcp-project"
region          = "us-central1"
cluster_name    = "my-educates"
dns_zone_name   = "my-dns-zone"
TLD             = "educates.example.com"
```

### Optional configuration

```hcl
zone             = "us-central1-a"    # Default: "{region}-a"
machine_type     = "e2-standard-4"    # Default
disk_size_gb     = 100                # Default
deploy_educates  = true               # Default
educates_version = "3.3.2"            # Default
```

## How to run

### Create

```
terraform init
terraform apply -var-file main.tfvars
```

### Connect via SSH

```bash
# Get the SSH connection details
terraform output ssh_connection

# SSH into the VM (private key is in terraform state)
terraform output -json gce | jq -r '.ssh_private_key' > /tmp/educates-ssh-key
chmod 600 /tmp/educates-ssh-key
ssh -i /tmp/educates-ssh-key educates@$(terraform output -json ssh_connection | jq -r '.host')
```

### Destroy

```
terraform destroy -var-file main.tfvars
```

## Differences from GKE/EKS root modules

| Aspect | GKE/EKS | GCE (this module) |
|--------|---------|-------------------|
| Kubernetes | Managed cluster (GKE/EKS) | Kind on a VM |
| Educates deployment | kapp-controller + kubectl provider | `educates` CLI via SSH |
| cert-manager auth | Workload Identity / IRSA | GCP SA key JSON |
| Providers needed | google, kubectl, kubernetes | google, tls, null |
| kubeconfig | Available locally | Lives on the VM |

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_google"></a> [google](#requirement\_google) | 6.47.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | ~> 2.5 |
| <a name="requirement_null"></a> [null](#requirement\_null) | ~> 3.2 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | 4.1.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_gce_for_local_educates"></a> [gce\_for\_local\_educates](#module\_gce\_for\_local\_educates) | ../../infrastructure/gce-for-local-educates | n/a |
| <a name="module_educates_local"></a> [educates\_local](#module\_educates\_local) | ../../platform/educates-local | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name used for resources and DNS records | `string` | n/a | yes |
| <a name="input_deploy_educates"></a> [deploy\_educates](#input\_deploy\_educates) | Whether to deploy/install Educates platform onto the VM | `bool` | `true` | no |
| <a name="input_disk_size_gb"></a> [disk\_size\_gb](#input\_disk\_size\_gb) | Boot disk size in GB | `number` | `100` | no |
| <a name="input_dns_zone_name"></a> [dns\_zone\_name](#input\_dns\_zone\_name) | Name of an existing Cloud DNS managed zone | `string` | n/a | yes |
| <a name="input_educates_version"></a> [educates\_version](#input\_educates\_version) | Educates version to use | `string` | `"3.3.2"` | no |
| <a name="input_machine_type"></a> [machine\_type](#input\_machine\_type) | GCE machine type for the compute instance | `string` | `"e2-standard-4"` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | GCP region | `string` | n/a | yes |
| <a name="input_TLD"></a> [TLD](#input\_TLD) | Top Level Domain to use for services deployed in the cluster | `string` | n/a | yes |
| <a name="input_zone"></a> [zone](#input\_zone) | GCP zone for the compute instance | `string` | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gce"></a> [gce](#output\_gce) | GCE instance details (sensitive) |
| <a name="output_educates"></a> [educates](#output\_educates) | Educates deployment details |
| <a name="output_ssh_connection"></a> [ssh\_connection](#output\_ssh\_connection) | SSH host and user for VM access |


## Connect via SSH

```
terraform state pull | jq -r '.. | select(.private_key_pem? != null) | .private_key_pem' > /tmp/educates-ssh-key
chmod 600 /tmp/educates-ssh-key

ssh -i /tmp/educates-ssh-key educates@$(terraform output -json ssh_connection | jq -r '.host')
```