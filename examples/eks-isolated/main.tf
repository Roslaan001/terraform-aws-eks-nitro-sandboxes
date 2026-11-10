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
      Example   = "eks-isolated"
      Project   = "terraform-aws-nitro-sandbox"
      ManagedBy = "Terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks_sandbox.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_sandbox.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_sandbox.cluster_name, "--region", var.aws_region]
  }
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

module "eks_sandbox" {
  source = "../../modules/eks"

  cluster_name           = "nitro-isolated-demo"
  aws_region             = var.aws_region
  sandbox_mode           = "isolated"
  deploy_sample_workload = true
  enable_auto_mode       = true
}

output "cluster_name" {
  value = module.eks_sandbox.cluster_name
}

output "sandbox_namespace" {
  value = module.eks_sandbox.sandbox_namespace
}

output "runtime_classes" {
  value = module.eks_sandbox.runtime_classes
}

output "verify_command" {
  value = "kubectl get pods -n ${module.eks_sandbox.sandbox_namespace} -o wide"
}
