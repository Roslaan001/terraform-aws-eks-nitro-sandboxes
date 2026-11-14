SHELL := /bin/bash
.PHONY: all fmt validate lint scan test plan-isolated plan-confidential apps-init apps-validate apps-test apps-plan clean help

all: fmt validate lint test apps-validate apps-test ## Run format, validation, linting, and tests (both stacks)

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

init: ## Initialize the platform stack (platform/)
	terraform -chdir=platform init -backend=false

fmt: ## Check and format all Terraform files
	terraform fmt -recursive

fmt-check: ## Check formatting without applying changes
	terraform fmt -check -recursive

validate: init ## Validate the platform stack
	terraform -chdir=platform validate

lint: ## Run TFLint recursively across all configurations
	tflint --init || true
	tflint --recursive

scan: ## Run Trivy IaC security configuration scanner
	trivy config --severity HIGH,CRITICAL .

test: init ## Run the platform stack tests
	terraform -chdir=platform test

plan-isolated: init ## Generate Terraform plan for Isolated Sandbox mode
	terraform -chdir=platform plan -var-file=isolated.tfvars

plan-confidential: init ## Generate Terraform plan for Confidential Sandbox mode
	terraform -chdir=platform plan -var-file=confidential.tfvars

apps-init: ## Initialize the apps stack (apps/)
	terraform -chdir=apps init

apps-validate: apps-init ## Validate the apps stack
	terraform -chdir=apps validate

apps-test: apps-init ## Run the apps stack and module tests
	terraform -chdir=apps test

apps-plan: apps-init ## Plan your apps (apps/*.yaml) against the running platform
	terraform -chdir=apps plan -out=tfplan

clean: ## Delete .terraform/, ALL local state (*.tfstate*), and plan files in both stacks. Only after destroy!
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
	find . -type f -name "*.tfstate*" -delete
	find . -type f -name "*.plan" -delete
	find . -type f -name "tfplan" -delete
	find . -type f -name "*.test.log" -delete
