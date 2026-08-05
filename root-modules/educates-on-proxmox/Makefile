# Makefile for robust and automated infrastructure deployment
.PHONY: help init plan apply destroy

# 1. Configuration
ALLOWED_FLAVORS := k3s rke2 talos
BACKENDS_DIR    := backends
VARS_DIR        := vars
BUILD_ROOT      := build

# Optional: pick a tfvars file other than vars/<FLAVOR>.tfvars (e.g. TFVARS=talos-on-axlab-test to
# use vars/talos-on-axlab-test.tfvars instead of the default vars/talos.tfvars). Base name, no extension.
TFVARS          ?= $(FLAVOR)
VARS_FILE       := $(VARS_DIR)/$(TFVARS).tfvars

ENVIRONMENT     := $(shell grep '^environment' $(VARS_FILE) | cut -d'"' -f2)
CLUSTER_NAME    := $(shell grep '^k8s_cluster_name' $(VARS_FILE) | cut -d'"' -f2)

# Optional parallelism parameter (defaults to empty so Terraform uses its internal default, or you can override like PARALLELISM=1)
PARALLELISM     ?=

# 2. Flavor Validation
ifeq ($(filter help,$(MAKECMDGOALS)),)
  ifndef FLAVOR
    $(error ERROR: FLAVOR is not defined. Use 'make [plan|apply|destroy] FLAVOR=k3s|rke2|talos [PARALLELISM=1]')
  endif
  ifneq ($(filter $(FLAVOR),$(ALLOWED_FLAVORS)),$(FLAVOR))
    $(error ERROR: FLAVOR must be one of [$(ALLOWED_FLAVORS)].)
  endif
endif

# Define artifact directory (scoped by flavor/environment/cluster_name, matching the backend state path)
ARTIFACT_DIR := $(BUILD_ROOT)/$(FLAVOR)/$(ENVIRONMENT)/$(CLUSTER_NAME)

# Help command
help:
	@echo "Terraform Infrastructure Manager"
	@echo "Usage: make [COMMAND] FLAVOR=[flavor] [TFVARS=name] [PARALLELISM=n]"
	@echo ""
	@echo "Commands (Terraform wrappers):"
	@echo "  plan     Initialize Terraform and generate execution plan"
	@echo "  apply    Apply the previously generated Terraform plan"
	@echo "  destroy  Destroy the infrastructure managed by Terraform"
	@echo ""
	@echo "Flavors:"
	@echo "  $(ALLOWED_FLAVORS)"
	@echo ""
	@echo "Parameters:"
	@echo "  TFVARS       Use vars/<name>.tfvars instead of vars/<FLAVOR>.tfvars (e.g. TFVARS=talos-on-axlab-test)"
	@echo "  PARALLELISM  Limit concurrent operations (e.g., PARALLELISM=1)"
	@echo "Example:"
	@echo "  make apply FLAVOR=talos PARALLELISM=1"
	@echo "  make plan FLAVOR=talos TFVARS=talos-on-axlab-test"

# Ensure build directory exists for artifacts
$(ARTIFACT_DIR):
	@mkdir -p $(ARTIFACT_DIR)

# Init: Sets up the backend for this flavor/environment/cluster combination.
# NOTE: the "local" backend has no "key" attribute (that's an S3-only concept), so state
# isolation here comes entirely from the "path" override below, one file per
# flavor/environment/cluster_name — not from Terraform workspaces (none are used).
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
	@echo "  make apply FLAVOR=$(FLAVOR)$(if $(filter-out $(FLAVOR),$(TFVARS)), TFVARS=$(TFVARS),)$(if $(PARALLELISM), PARALLELISM=$(PARALLELISM),)"
	@echo "=========================================================="

# Apply: Uses the artifact from the build directory
apply: init
	@echo "--- Applying configuration for $(FLAVOR) ---"
	@terraform apply \
		$(if $(PARALLELISM),-parallelism=$(PARALLELISM),) \
		"$(ARTIFACT_DIR)/$(FLAVOR).tfplan"

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