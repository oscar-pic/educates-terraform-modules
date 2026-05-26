# Educates Deployment on Proxmox with Terraform

This directory contains the Terraform configuration required to deploy the **Educates** infrastructure on a **Proxmox VE** virtualization environment.

It is designed to provision virtual nodes (typically based on Ubuntu Cloud Images) and configure a Kubernetes cluster (K3s) using the Proxmox provider and Cloud-init for automated bootstrapping.

## Prerequisites

* **Terraform**: Version 1.3 or higher installed locally.
* **Proxmox VE**: A functional Proxmox cluster or node with API access.
* **API Token**: A Proxmox API Token with sufficient permissions to create virtual machines, manage storage, and upload snippets.
* **SSH Access**: An SSH key pair configured on your local machine for Proxmox node access and VM injection.

## Configuration

To configure the deployment, you must create a `terraform.tfvars` file in this directory. You can use the provided example file as a template:

```bash
cp terraform.tfvars.k3s_example terraform.tfvars
```

### Key Variables

Edit the `terraform.tfvars` file to match your environment:

* **proxmox_endpoint**: The API URL of your Proxmox server (e.g., `https://192.168.1.100:8006/`).
* **proxmox_api_token**: Your authentication token (format: `user@pve!token_id=secret`).
* **proxmox_nodes**: An array of the physical node names in your Proxmox cluster.
* **deployment_flavor**: Defines the deployment type (e.g., `single-node-k3s`).
* **kube_nodes**: A map defining the virtual machines, including resources (CPU, RAM), networking (IP, Gateway, Bridge), and login credentials.

## Deployment

Once the variables are configured, run the standard Terraform workflow:

1. **Initialize the directory**:

   ```bash
   terraform init -reconfigure
   ```

2. **Preview the execution plan**:

   ```bash
   terraform plan -var-file="k3s.tfvars" -out="k3s.tfplan"
   #or
   terraform plan -var-file="rke2.tfvars" -out="rke2.tfplan"
   ```

3. **Apply the changes**:

   ```bash
   terraform apply "k3s.tfplan"
   #or
   terraform apply "rke2.tfplan"
   ```

## Post-Installation

After the deployment is complete, the virtual machines will boot and start the provisioning process via Cloud-init.

To retrieve the `kubeconfig` file and start interacting with your cluster:

1. SSH into the master node (using the IP defined in your `kube_nodes`).
2. The config file is located at `/etc/rancher/k3s/k3s.yaml` (for K3s installations).

## Infrastructure Deletion

To remove all resources created in Proxmox:

```bash
terraform destroy -var-file="k3s.tfvars"
#or
terraform destroy -var-file="rke2.tfvars"
```

---

### Technical Notes (Based on your example)

* **Storage**: Ensure the datastore defined in `proxmox_images_snippets_datastore` (default is `local`) allows both **ISO** and **Snippets** content types, as it is used for downloading the OS image and hosting Cloud-init configuration files.
* **Networking**: The `network_bridge` value (typically `vmbr0`) must exist on the target Proxmox node.
