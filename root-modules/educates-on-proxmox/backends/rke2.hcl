# Fallback default if you run `terraform init` directly. Makefile/deploy.ps1 always
# override this with a path scoped by environment/cluster_name (see Makefile's
# "init" target), so multiple clusters/environments never share the same state file.
path = "build/rke2/rke2.tfstate"

# Example if we want to use an external S3
#bucket = "my-bucket"
#key    = "states/rke2.tfstate"
#region = "eu-central-1"