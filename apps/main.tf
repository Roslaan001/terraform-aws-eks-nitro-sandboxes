# Apps stack: your applications, in their own Terraform state, separate from the platform (platform/).
#
#   cd apps && terraform init && terraform plan -out=tfplan && terraform apply tfplan
#
# Each app is one file next to this one: apps/<name>.yaml (the file name is the app name), or an
# entry in var.workloads. Everything is passed to ../modules/sandbox-workload, which applies types,
# defaults and validation. The platform is found by name through data sources, so this stack never
# reads or changes the platform's state, and adding an app never touches the VPC, EKS or platform KMS key.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "terraform-aws-nitro-sandbox"
      ManagedBy   = "Terraform"
      Environment = var.environment
      Stack       = "apps"
    }
  }
}

# --- The platform, looked up by name (created by the stack in platform/) ---

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_kms_alias" "platform" {
  name = "alias/${var.cluster_name}-key"
}

# Configured from a data source, not a resource: this is what lets each app's KMS key reference its
# role without a dependency cycle.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}

# --- Apps ---

locals {
  apps_dir  = abspath(var.apps_dir == null ? path.module : var.apps_dir)
  app_files = fileset(local.apps_dir, "*.yaml")

  file_workloads = {
    for f in local.app_files : trimsuffix(f, ".yaml") => yamldecode(file("${local.apps_dir}/${f}"))
  }

  duplicate_workload_names = setintersection(keys(local.file_workloads), keys(var.workloads))

  all_workloads = merge(local.file_workloads, var.workloads)
}

module "workload" {
  source   = "../modules/sandbox-workload"
  for_each = toset(keys(local.all_workloads))

  name          = each.key
  config        = local.all_workloads[each.key]
  namespace     = var.namespace
  sandbox_modes = var.sandbox_modes
  cluster_name  = data.aws_eks_cluster.this.name
  aws_region    = var.aws_region
  account_id    = data.aws_caller_identity.current.account_id
  partition     = data.aws_partition.current.partition
  kms_key_arn   = data.aws_kms_alias.platform.target_key_arn
  tags          = var.tags
}
