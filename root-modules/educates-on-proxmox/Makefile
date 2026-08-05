# Makefile for robust and automated infrastructure deployment
.PHONY: help init plan apply destroy

# 1. Configuration
ALLOWED_FLAVORS := k3s rke2 talos
BACKENDS_DIR    := backends
VARS_DIR        := vars
BUILD_ROOT      := build

# Required: which tfvars file to use (e.g. TFVARS=talos-on-axlab-test for
# vars/talos-on-axlab-test.tfvars). Base name, no extension. There's no default and no separate
# FLAVOR parameter: the flavor is derived below from the tfvars file's own 'deployment_flavor'
# variable, so there's only one place that can ever disagree with itself.
VARS_FILE       := $(VARS_DIR)/$(TFVARS).tfvars

ENVIRONMENT     := $(shell grep '^environment' $(VARS_FILE) 2>/dev/null | cut -d'"' -f2)
CLUSTER_NAME    := $(shell grep '^k8s_cluster_name' $(VARS_FILE) 2>/dev/null | cut -d'"' -f2)
FLAVOR          := $(shell grep '^deployment_flavor' $(VARS_FILE) 2>/dev/null | cut -d'"' -f2)

# Optional parallelism parameter (defaults to empty so Terraform uses its internal default, or you can override like PARALLELISM=1)
PARALLELISM     ?=

# 2. Validation
ifeq ($(filter help,$(MAKECMDGOALS)),)
  ifndef TFVARS
    $(error ERROR: TFVARS is not defined. Use 'make [plan|apply|destroy] TFVARS=<name> [PARALLELISM=1]')
  endif
  ifeq ($(wildcard $(VARS_FILE)),)
    $(error ERROR: $(VARS_FILE) not found.)
  endif
  ifneq ($(filter $(FLAVOR),$(ALLOWED_FLAVORS)),$(FLAVOR))
    $(error ERROR: deployment_flavor '$(FLAVOR)' inside $(VARS_FILE) must be one of [$(ALLOWED_FLAVORS)].)
  endif
endif

# Define artifact directory (scoped by environment/cluster_name, matching the backend state path --
# flavor isn't part of the path: cluster_name is already globally unique, so it added nothing)
ARTIFACT_DIR := $(BUILD_ROOT)/$(ENVIRONMENT)/$(CLUSTER_NAME)

# Help command
help:
	@echo "Terraform Infrastructure Manager"
	@echo "Usage: make [COMMAND] TFVARS=<name> [PARALLELISM=n]"
	@echo ""
	@echo "Commands (Terraform wrappers):"
	@echo "  plan     Initialize Terraform and generate execution plan"
	@echo "  apply    Apply the previously generated Terraform plan"
	@echo "  destroy  Destroy the infrastructure managed by Terraform"
	@echo ""
	@echo "Flavors (read from 'deployment_flavor' inside the tfvars file, not a separate parameter):"
	@echo "  $(ALLOWED_FLAVORS)"
	@echo ""
	@echo "Parameters:"
	@echo "  TFVARS       Required. Use vars/<name>.tfvars (e.g. TFVARS=talos-on-axlab-test)"
	@echo "  PARALLELISM  Limit concurrent operations (e.g., PARALLELISM=1)"
	@echo "Example:"
	@echo "  make apply TFVARS=talos-on-axlab-test PARALLELISM=1"
	@echo "  make plan TFVARS=talos-on-axlab-test"

# Ensure build directory exists for artifacts
$(ARTIFACT_DIR):
	@mkdir -p $(ARTIFACT_DIR)

# Init: Sets up the backend for this cluster's state.
# NOTE: the "local" backend has no "key" attribute (that's an S3-only concept), so state
# isolation here comes entirely from the "path" override below, one file per
# environment/cluster_name (already globally unique on its own) — not from Terraform
# workspaces (none are used).
init: $(ARTIFACT_DIR)
	@echo "--- Initializing backend for $(FLAVOR) ($(ENVIRONMENT)/$(CLUSTER_NAME)) ---"

	@# Migration safety net: older versions of this Makefile used a workspace per flavor.
	@# The local backend's workspace suffix takes priority over a custom "path" whenever
	@# the current workspace isn't "default", so any leftover non-default workspace must
	@# be cleared first, or the "path" override below would silently be ignored.
	@terraform workspace select default > /dev/null 2>&1 || true

	@terraform init \
		-backend-config=$(BACKENDS_DIR)/$(FLAVOR).hcl \
		-backend-config="path=$(ARTIFACT_DIR)/terraform.tfstate" \
		-input=false \
		-no-color \
		> $(ARTIFACT_DIR)/$(FLAVOR)-tfinit.log 2>&1 || \
	( \
		echo "--- Terraform init failed, retrying with state migration ---"; \
		terraform init \
			-backend-config=$(BACKENDS_DIR)/$(FLAVOR).hcl \
			-backend-config="path=$(ARTIFACT_DIR)/terraform.tfstate" \
			-migrate-state \
			-input=false \
			-no-color \
			>> $(ARTIFACT_DIR)/$(FLAVOR)-tfinit.log 2>&1 || \
		( \
			echo "--- Terraform init failed. Full log:"; \
			cat $(ARTIFACT_DIR)/$(FLAVOR)-tfinit.log; \
			exit 1; \
		) \
	)

# Plan: Generates an artifact in the build directory
plan: init
	@echo "--- Generating plan for $(FLAVOR) ---"

	@terraform plan \
		-var-file=$(VARS_FILE) \
		$(if $(PARALLELISM),-parallelism=$(PARALLELISM),) \
		-out=$(ARTIFACT_DIR)/$(FLAVOR).tfplan \
		-no-color \
		> $(ARTIFACT_DIR)/$(FLAVOR)-tfplan.log

	@echo "================================"
	@echo " Terraform Plan Summary"
	@echo "================================"
	@grep "^Plan:" $(ARTIFACT_DIR)/$(FLAVOR)-tfplan.log || true
	@echo "================================"
	
	@echo ""
	@echo "=========================================================="
	@echo "Plan generated successfully."
	@echo "To apply this plan, run:"
	@echo "  make apply TFVARS=$(TFVARS)$(if $(PARALLELISM), PARALLELISM=$(PARALLELISM),)"
	@echo "=========================================================="

# Apply: Uses the artifact from the build directory
# Retries once on failure: the bpg/proxmox provider has a known race when several VMs are
# added to the same Pool in the same apply (creating a cluster's nodes for the first time, or
# scaling it) -- one of the concurrent "add to pool" calls can 500 with "VM X is already a pool
# member" even though the VM itself was created fine and IS in the pool. Terraform still marks
# that resource's apply as failed, which skips everything downstream of it in the same run
# (e.g. a CSI replica-count Helm upgrade never runs). The retry re-applies against the tfvars
# directly (not the saved plan, which may be stale after a partial apply) -- safe, since
# Terraform apply is idempotent and the first attempt's real resources are already in state.
apply: init
	@echo "--- Applying configuration for $(FLAVOR) ---"
	@terraform apply \
		$(if $(PARALLELISM),-parallelism=$(PARALLELISM),) \
		"$(ARTIFACT_DIR)/$(FLAVOR).tfplan" || \
	( \
		echo "--- Apply failed, retrying once (known bpg/proxmox Pool-membership race -- see comment above) ---"; \
		sleep 5; \
		terraform apply \
			-auto-approve \
			-var-file=$(VARS_FILE) \
			$(if $(PARALLELISM),-parallelism=$(PARALLELISM),) \
	)

# Destroy: Validated destroy
destroy: init
	@echo "--- DESTROYING infrastructure for $(FLAVOR) ---"

	@terraform destroy \
		-var-file=$(VARS_FILE) \
		$(if $(PARALLELISM),-parallelism=$(PARALLELISM),) \
		-auto-approve \
		-no-color \
		> $(ARTIFACT_DIR)/$(FLAVOR)-tfdestroy.log 2>&1 || \
	( \
		echo "--- Terraform destroy failed. Full log:"; \
		cat $(ARTIFACT_DIR)/$(FLAVOR)-tfdestroy.log; \
		exit 1; \
	)
	
	@echo ""
	@echo "=========================================================="
	@echo "Destroy completed successfully."
	@echo "Detailed log saved to:"
	@echo "  $(ARTIFACT_DIR)/$(FLAVOR)-tfdestroy.log"
	@echo "=========================================================="