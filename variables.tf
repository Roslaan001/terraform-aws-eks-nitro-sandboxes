variable "aws_region" {
  description = "AWS Region to deploy resources into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment identifier (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the Amazon EKS cluster"
  type        = string
  default     = "nitro-sandbox-eks"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-_]+$", var.cluster_name))
    error_message = "Cluster name must contain only alphanumeric characters, hyphens, and underscores."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of Availability Zones for VPC subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "enable_auto_mode" {
  description = "Enable EKS Auto Mode (manages compute, storage, and networking with native Nitro Sandbox support)"
  type        = bool
  default     = true
}

variable "node_pools" {
  description = "EKS Auto Mode node pools to enable"
  type        = list(string)
  default     = ["general-purpose", "system"]
}

variable "cluster_endpoint_public_access" {
  description = "Whether the Amazon EKS public API server endpoint is enabled"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks allowed to access the EKS public API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "sandbox_namespace" {
  description = "Kubernetes namespace for deploying sandboxed workloads"
  type        = string
  default     = "nitro-sandboxes"
}

variable "sandbox_modes" {
  description = "List of Nitro Sandbox modes to enable in the cluster ('isolated', 'confidential', or both)"
  type        = list(string)
  default     = ["isolated", "confidential"]

  validation {
    condition     = length(var.sandbox_modes) > 0 && alltrue([for m in var.sandbox_modes : contains(["isolated", "confidential"], m)])
    error_message = "sandbox_modes must be a non-empty list containing only 'isolated' and/or 'confidential'."
  }
}

variable "manage_runtime_classes" {
  description = "Whether Terraform should manage the Kubernetes RuntimeClass resources"
  type        = bool
  default     = true
}

variable "enable_workload_runtime_class" {
  description = "Whether to attach runtimeClassName directly to the sample workload pod spec (requires Nitro Sandbox containerd shim on worker nodes)"
  type        = bool
  default     = false
}

variable "confidential_expected_image_digest" {
  description = "Expected image SHA-384 digest for KMS hardware attestation condition policy"
  type        = string
  default     = ""
}

variable "deploy_sample_workload" {
  description = "Whether to deploy the verified sample sandboxed workload"
  type        = bool
  default     = true
}

variable "sample_workload_image" {
  description = "Container image for the sample sandboxed workload"
  type        = string
  default     = "public.ecr.aws/nginx/nginx-unprivileged:latest"
}

variable "sample_workload_replicas" {
  description = "Number of replicas for each sample workload deployment"
  type        = number
  default     = 2

  validation {
    condition     = var.sample_workload_replicas >= 1 && var.sample_workload_replicas <= 10
    error_message = "Sample workload replicas must be between 1 and 10."
  }
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
