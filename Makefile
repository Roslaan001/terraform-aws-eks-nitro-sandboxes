SHELL := /bin/bash
.PHONY: all fmt validate lint scan test plan-isolated plan-confidential clean help

all: fmt validate lint test ## Run format, validation, linting, and tests

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

init: ## Initialize root Terraform configuration
	terraform init -backend=false

fmt: ## Check and format all Terraform files
	terraform fmt -recursive

fmt-check: ## Check formatting without applying changes
	terraform fmt -check -recursive

validate: init ## Validate Terraform configuration
	terraform validate

lint: ## Run TFLint recursively across all configurations
	tflint --init || true
	tflint --recursive

scan: ## Run Trivy IaC security configuration scanner
	trivy config --severity HIGH,CRITICAL .

test: ## Run native Terraform unit and mock tests
	terraform test

plan-isolated: init ## Generate Terraform plan for Isolated Sandbox mode
	terraform plan -var-file=isolated.tfvars

plan-confidential: init ## Generate Terraform plan for Confidential Sandbox mode
	terraform plan -var-file=confidential.tfvars

clean: ## Clean up local Terraform state caches and logs
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
	find . -type f -name "*.tfstate*" -delete
	find . -type f -name "*.plan" -delete
	find . -type f -name "*.test.log" -delete
