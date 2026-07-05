param (
    [Parameter(Mandatory=$false)] [string]$Flavor,
    [Parameter(Mandatory=$false)] [ValidateSet("plan", "apply", "destroy")] [string]$Action,
    [Parameter(Mandatory=$false)] [switch]$Help
)

# 1. Help message display
if ($Help -or ($PSBoundParameters.Count -eq 0)) {
    Write-Host @"
Terraform Infrastructure Manager
Usage: .\deploy.ps1 -Flavor [k3s|rke2|talos] -Action [plan|apply|destroy]

Commands (Terraform wrappers):
  plan     Initialize Terraform and generate execution plan
  apply    Apply the previously generated Terraform plan
  destroy  Destroy the infrastructure managed by Terraform

Example:
  .\deploy.ps1 -Flavor k3s -Action plan
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
$ArtifactDir = "build/$Flavor"
$BackendFile = "backends/$Flavor.hcl"

# 3. Ensure build directory exists for artifacts
if (-not (Test-Path $ArtifactDir)) { New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null }

# 4. Prepare workspace and init
Write-Host "--- Initializing backend and workspace for $Flavor ---"

# Init with backend config
terraform init -backend-config="$BackendFile" -input=false
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- Backend migration required, attempting automatic migration ---"
    terraform init -backend-config="$BackendFile" -migrate-state -input=false
    if ($LASTEXITCODE -ne 0) {
        Write-Error "ERROR: Failed to initialize backend."
        exit 1
    }
}

# Handle workspace: select or create
$CurrentWs = terraform workspace show
if ($CurrentWs -ne $Flavor) {
    Write-Host "Switching to workspace: $Flavor"
    terraform workspace select $Flavor 2>$null
    if ($LASTEXITCODE -ne 0) {
        terraform workspace new $Flavor
    }
}

# Final safety check
if ((terraform workspace show) -ne $Flavor) {
    Write-Error "CRITICAL ERROR: Workspace mismatch! Expected $Flavor, but currently in $(terraform workspace show)"
    exit
}

# 3. Ensure build dir exists
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

# 4. Execute
switch ($Action) {
    "plan" {
        Write-Host "--- Generating plan for $Flavor ---"
        terraform plan -var-file="vars/$Flavor.tfvars" -out="$ArtifactDir/$Flavor.tfplan"
        # Check if the previous command was successful ($LASTEXITCODE 0 means success)
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "==========================================================" -ForegroundColor Cyan
            Write-Host "Plan generated successfully."
            Write-Host "To apply this plan, run:"
            Write-Host "  .\deploy.ps1 -Flavor $Flavor -Action apply"
            Write-Host "==========================================================" -ForegroundColor Cyan
        }
    }
    "apply" {
        Write-Host "--- Applying configuration for $Flavor ---"
        terraform apply "$ArtifactDir/$Flavor.tfplan"
    }
    "destroy" {
        Write-Host "--- DESTROYING infrastructure for $Flavor ---"
        terraform destroy -var-file="vars/$Flavor.tfvars" -auto-approve
    }
}