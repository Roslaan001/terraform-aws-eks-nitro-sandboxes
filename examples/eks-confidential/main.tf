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
      Example   = "eks-confidential"
      Project   = "terraform-aws-nitro-sandbox"
      ManagedBy = "Terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks_confidential.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_confidential.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks_confidential.cluster_name, "--region", var.aws_region]
  }
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "expected_image_digest" {
  description = "Expected SHA-384 digest of the confidential container image for KMS attestation verification"
  type        = string
  default     = "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
}

module "eks_confidential" {
  source = "../../modules/eks"

  cluster_name                       = "nitro-confidential-demo"
  aws_region                         = var.aws_region
  sandbox_mode                       = "confidential"
  confidential_expected_image_digest = var.expected_image_digest
  deploy_sample_workload             = true
  enable_auto_mode                   = true
}

output "cluster_name" {
  value = module.eks_confidential.cluster_name
}

output "kms_key_arn" {
  value = module.eks_confidential.kms_key_arn
}

output "sandbox_namespace" {
  value = module.eks_confidential.sandbox_namespace
}

output "verify_attestation_command" {
  value = "kubectl exec -n ${module.eks_confidential.sandbox_namespace} deploy/nitro-sandbox-sample -- /bin/sh -c 'ls -l /dev/nsm'"
}
