# Makefile for robust and automated infrastructure deployment
.PHONY: help init plan apply destroy

# 1. Configuration
ALLOWED_FLAVORS := k3s rke2 talos
BACKENDS_DIR    := backends
VARS_DIR        := vars
BUILD_ROOT      := build

# 2. Flavor Validation
ifeq ($(filter help,$(MAKECMDGOALS)),)
  ifndef FLAVOR
    $(error ERROR: FLAVOR is not defined. Use 'make [plan|apply|destroy] FLAVOR=k3s|rke2|talos')
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
	@echo "Usage: make [COMMAND] FLAVOR=[flavor]"
	@echo ""
	@echo "Commands (Terraform wrappers):"
	@echo "  plan     Initialize Terraform and generate execution plan"
	@echo "  apply    Apply the previously generated Terraform plan"
	@echo "  destroy  Destroy the infrastructure managed by Terraform"
	@echo ""
	@echo "Flavors:"
	@echo "  $(ALLOWED_FLAVORS)"
	@echo "Example:"
	@echo "  make plan FLAVOR=k3s"

# Ensure build directory exists for artifacts
$(ARTIFACT_DIR):
	@mkdir -p $(ARTIFACT_DIR)

# Init: Sets up backend and ensures we are in the right Workspace with validation
init: $(ARTIFACT_DIR)
	@echo "--- Initializing workspace and backend for $(FLAVOR) ---"
	@terraform init -backend-config=$(BACKENDS_DIR)/$(FLAVOR).hcl || \
	(echo "--- Backend mismatch detected, attempting migration ---" && \
	 terraform init -backend-config=$(BACKENDS_DIR)/$(FLAVOR).hcl -migrate-state -input=false)
	@terraform workspace select $(FLAVOR) || terraform workspace new $(FLAVOR)
	@# Critical Safety Check: Validate we are in the correct workspace before any action
	@if [ "$$(terraform workspace show)" != "$(FLAVOR)" ]; then \
		echo "CRITICAL ERROR: Workspace mismatch! Expected $(FLAVOR), but currently in $$(terraform workspace show)"; \
		exit 1; \
	fi

# Plan: Generates an artifact in the build directory
plan: init
	@echo "--- Generating plan for $(FLAVOR) ---"
	terraform plan -var-file=$(VARS_DIR)/$(FLAVOR).tfvars -out=$(ARTIFACT_DIR)/$(FLAVOR).tfplan

# Apply: Uses the artifact from the build directory
apply: init
	@echo "--- Applying configuration for $(FLAVOR) ---"
	terraform apply "$(ARTIFACT_DIR)/$(FLAVOR).tfplan"

# Destroy: Validated destroy
destroy: init
	@echo "--- DESTROYING infrastructure for $(FLAVOR) ---"
	terraform destroy -var-file=$(VARS_DIR)/$(FLAVOR).tfvars -auto-approve