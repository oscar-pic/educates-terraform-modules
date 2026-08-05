param (
    [Parameter(Mandatory=$false)] [ValidateSet("plan", "apply", "destroy")] [string]$Action,
    [Parameter(Mandatory=$false)] [int]$Parallelism,
    [Parameter(Mandatory=$false)] [string]$TfVars,
    [Parameter(Mandatory=$false)] [switch]$Help
)

# 1. Help message display
if ($Help -or ($PSBoundParameters.Count -eq 0)) {
    Write-Host @"
Terraform Infrastructure Manager
Usage: .\deploy.ps1 -Action [plan|apply|destroy] -TfVars name [-Parallelism n]

Commands (Terraform wrappers):
  plan     Initialize Terraform and generate execution plan
  apply    Apply the previously generated Terraform plan
  destroy  Destroy the infrastructure managed by Terraform

Parameters:
  -TfVars       Required. Use vars/<name>.tfvars (e.g. -TfVars talos-on-axlab-test)
  -Parallelism  Limit concurrent operations (e.g., -Parallelism 1)

There's no -Flavor parameter: the flavor is read from 'deployment_flavor' inside the tfvars
file itself, same as the Makefile -- one source of truth, so it can never disagree with what
actually gets deployed.

Example:
  .\deploy.ps1 -Action plan -TfVars k3s
  .\deploy.ps1 -Action apply -TfVars talos -Parallelism 1
  .\deploy.ps1 -Action plan -TfVars talos-on-axlab-test
"@
    exit
}

# 2. Strict validation of parameters
if (-not $TfVars -or -not $Action) {
    Write-Error "ERROR: Missing or invalid parameters. Use -Help to see usage."
    exit
}

$ErrorActionPreference = "Stop"
$VarsFile = "vars/$TfVars.tfvars"
if (-not (Test-Path $VarsFile)) {
    Write-Error "ERROR: $VarsFile not found."
    exit 1
}
$ParallelismArgs = if ($Parallelism) { @("-parallelism=$Parallelism") } else { @() }

# 3. Discover flavor/environment/cluster_name from the tfvars file (same source as the state path)
function Get-TfvarsValue($Path, $Name) {
    $line = Select-String -Path $Path -Pattern "^$Name\s*=\s*`"([^`"]*)`"" | Select-Object -First 1
    if (-not $line) {
        Write-Error "ERROR: could not find '$Name' in $Path"
        exit 1
    }
    return $line.Matches[0].Groups[1].Value
}

$AllowedFlavors = @("k3s", "rke2", "talos")
$Flavor = Get-TfvarsValue -Path $VarsFile -Name "deployment_flavor"
if ($AllowedFlavors -notcontains $Flavor) {
    Write-Error "ERROR: deployment_flavor '$Flavor' inside $VarsFile must be one of: $($AllowedFlavors -join ', ')."
    exit 1
}
$BackendFile = "backends/$Flavor.hcl"
$Environment = Get-TfvarsValue -Path $VarsFile -Name "environment"
$ClusterName = Get-TfvarsValue -Path $VarsFile -Name "k8s_cluster_name"

# Artifact directory (scoped by environment/cluster_name, matching the backend state path --
# flavor isn't part of the path: cluster_name is already globally unique, so it added nothing)
$ArtifactDir = "build/$Environment/$ClusterName"
$StatePath = "$ArtifactDir/terraform.tfstate"

# 4. Ensure build directory exists for artifacts
if (-not (Test-Path $ArtifactDir)) { New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null }

# 5. Init the backend for this cluster's state.
# NOTE: the "local" backend has no "key" attribute (that's an S3-only concept), so state
# isolation here comes entirely from the "path" override below, one file per
# environment/cluster_name (already globally unique on its own) — not from Terraform
# workspaces (none are used).
Write-Host "--- Initializing backend for $ClusterName ($Flavor) ---"

# Migration safety net: older versions of this script used a workspace per flavor. The
# local backend's workspace suffix takes priority over a custom "path" whenever the
# current workspace isn't "default", so any leftover non-default workspace must be
# cleared first, or the "path" override below would silently be ignored.
terraform workspace select default 2>$null | Out-Null

terraform init -backend-config="$BackendFile" -backend-config="path=$StatePath" -input=false
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- Backend migration required, attempting automatic migration ---"
    terraform init -backend-config="$BackendFile" -backend-config="path=$StatePath" -migrate-state -input=false
    if ($LASTEXITCODE -ne 0) {
        Write-Error "ERROR: Failed to initialize backend."
        exit 1
    }
}

# 6. Execute
switch ($Action) {
    "plan" {
        Write-Host "--- Generating plan for $Flavor ---"
        terraform plan -var-file="$VarsFile" @ParallelismArgs -out="$ArtifactDir/$Flavor.tfplan"
        # Check if the previous command was successful ($LASTEXITCODE 0 means success)
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Cyan
            Write-Host "Plan generated successfully."
            Write-Host "To apply this plan, run:"
            Write-Host "  .\deploy.ps1 -Action apply -TfVars $TfVars$(if ($Parallelism) { " -Parallelism $Parallelism" })"
            Write-Host "==========================================================" -ForegroundColor Cyan
        }
    }
    "apply" {
        Write-Host "--- Applying configuration for $Flavor ---"
        terraform apply @ParallelismArgs "$ArtifactDir/$Flavor.tfplan"
    }
    "destroy" {
        Write-Host "--- DESTROYING infrastructure for $Flavor ---"
        terraform destroy -var-file="$VarsFile" @ParallelismArgs -auto-approve
    }
}
