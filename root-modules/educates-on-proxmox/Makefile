# Makefile for robust and automated infrastructure deployment
.PHONY: help init plan apply destroy

# 1. Configuration
ALLOWED_FLAVORS := k3s rke2 talos
BACKENDS_DIR    := backends
VARS_DIR        := vars
BUILD_ROOT      := build
ENVIRONMENT     := $(shell grep '^environment' vars/$(FLAVOR).tfvars | cut -d'"' -f2)
CLUSTER_NAME    := $(shell grep '^k8s_cluster_name' vars/$(FLAVOR).tfvars | cut -d'"' -f2)

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

# Define artifact directory
ARTIFACT_DIR := $(BUILD_ROOT)/$(FLAVOR)

# Help command
help:
	@echo "Terraform Infrastructure Manager"
	@echo "Usage: make [COMMAND] FLAVOR=[flavor] [PARALLELISM=n]"
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
	@echo "  PARALLELISM  Limit concurrent operations (e.g., PARALLELISM=1)"
	@echo "Example:"
	@echo "  make apply FLAVOR=talos PARALLELISM=1"

# Ensure build directory exists for artifacts
$(ARTIFACT_DIR):
	@mkdir -p $(ARTIFACT_DIR)

# Init: Sets up backend and ensures we are in the right Workspace with validation
init: $(ARTIFACT_DIR)
	@echo "--- Initializing workspace and backend for $(FLAVOR) ---"

	@terraform init \
		-backend-config=$(BACKENDS_DIR)/$(FLAVOR).hcl \
		-backend-config="key=$(ENVIRONMENT)/$(CLUSTER_NAME)/terraform.tfstate" \
		-input=false \
		-no-color \
		> $(ARTIFACT_DIR)/$(FLAVOR)-tfinit.log 2>&1 || \
	( \
		echo "--- Terraform init failed. Full log:"; \
		cat $(ARTIFACT_DIR)/$(FLAVOR)-tfinit.log; \
		exit 1; \
	)

	@terraform workspace select $(FLAVOR) > /dev/null 2>&1 || \
	terraform workspace new $(FLAVOR) > /dev/null 2>&1

	@if [ "$$(terraform workspace show)" != "$(FLAVOR)" ]; then \
		echo "CRITICAL ERROR: Workspace mismatch! Expected $(FLAVOR), but currently in $$(terraform workspace show)"; \
		exit 1; \
	fi

# Plan: Generates an artifact in the build directory
plan: init
	@echo "--- Generating plan for $(FLAVOR) ---"

	@terraform plan \
		-var-file=$(VARS_DIR)/$(FLAVOR).tfvars \
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
	@echo "  make apply FLAVOR=$(FLAVOR)$(if $(PARALLELISM), PARALLELISM=$(PARALLELISM),)"
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
		-var-file=$(VARS_DIR)/$(FLAVOR).tfvars \
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