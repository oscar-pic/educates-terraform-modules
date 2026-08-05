param (
    [Parameter(Mandatory=$false)] [string]$Flavor,
    [Parameter(Mandatory=$false)] [ValidateSet("plan", "apply", "destroy")] [string]$Action,
    [Parameter(Mandatory=$false)] [int]$Parallelism,
    [Parameter(Mandatory=$false)] [string]$TfVars,
    [Parameter(Mandatory=$false)] [switch]$Help
)

# 1. Help message display
if ($Help -or ($PSBoundParameters.Count -eq 0)) {
    Write-Host @"
Terraform Infrastructure Manager
Usage: .\deploy.ps1 -Flavor [k3s|rke2|talos] -Action [plan|apply|destroy] [-TfVars name] [-Parallelism n]

Commands (Terraform wrappers):
  plan     Initialize Terraform and generate execution plan
  apply    Apply the previously generated Terraform plan
  destroy  Destroy the infrastructure managed by Terraform

Parameters:
  -TfVars       Use vars/<name>.tfvars instead of vars/<Flavor>.tfvars (e.g. -TfVars talos-on-axlab-test)
  -Parallelism  Limit concurrent operations (e.g., -Parallelism 1)

Example:
  .\deploy.ps1 -Flavor k3s -Action plan
  .\deploy.ps1 -Flavor talos -Action apply -Parallelism 1
  .\deploy.ps1 -Flavor talos -Action plan -TfVars talos-on-axlab-test
"@
    exit
}

# 2. Strict validation of parameters
$AllowedFlavors = @("k3s", "rke2", "talos")
if ($AllowedFlavors -notcontains $Flavor -or -not $Action) {
    Write-Error "ERROR: Missing or invalid parameters. Use -Help to see usage."
    exit
}

$ErrorActionPreference = "Stop"
$BackendFile = "backends/$Flavor.hcl"
$TfVarsName = if ($TfVars) { $TfVars } else { $Flavor }
$VarsFile = "vars/$TfVarsName.tfvars"
$ParallelismArgs = if ($Parallelism) { @("-parallelism=$Parallelism") } else { @() }

# 3. Discover environment/cluster_name from the tfvars file (same source as the state path)
function Get-TfvarsValue($Path, $Name) {
    $line = Select-String -Path $Path -Pattern "^$Name\s*=\s*`"([^`"]*)`"" | Select-Object -First 1
    if (-not $line) {
        Write-Error "ERROR: could not find '$Name' in $Path"
        exit 1
    }
    return $line.Matches[0].Groups[1].Value
}

$Environment = Get-TfvarsValue -Path $VarsFile -Name "environment"
$ClusterName = Get-TfvarsValue -Path $VarsFile -Name "k8s_cluster_name"

# Artifact directory (scoped by flavor/environment/cluster_name, matching the backend state path)
$ArtifactDir = "build/$Flavor/$Environment/$ClusterName"
$StatePath = "$ArtifactDir/terraform.tfstate"

# 4. Ensure build directory exists for artifacts
if (-not (Test-Path $ArtifactDir)) { New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null }

# 5. Init the backend for this flavor/environment/cluster combination.
# NOTE: the "local" backend has no "key" attribute (that's an S3-only concept), so state
# isolation here comes entirely from the "path" override below, one file per
# flavor/environment/cluster_name — not from Terraform workspaces (none are used).
Write-Host "--- Initializing backend for $Flavor ($Environment/$ClusterName) ---"

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
            Write-Host "  .\deploy.ps1 -Flavor $Flavor -Action apply$(if ($TfVars) { " -TfVars $TfVars" })$(if ($Parallelism) { " -Parallelism $Parallelism" })"
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
