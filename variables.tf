variable "aws_region" {
  description = "The AWS Region to deploy resources into"
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
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for subnet allocation"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "enable_auto_mode" {
  description = "Enable EKS Auto Mode with native Nitro Sandbox support"
  type        = bool
  default     = true
}

variable "sandbox_mode" {
  description = "Execution mode for Nitro Sandboxes ('isolated' or 'confidential')"
  type        = string
  default     = "isolated"

  validation {
    condition     = contains(["isolated", "confidential"], var.sandbox_mode)
    error_message = "sandbox_mode must be either 'isolated' or 'confidential'."
  }
}

variable "confidential_expected_image_digest" {
  description = "SHA-384 measurement hash of the container image for KMS attestation in confidential mode"
  type        = string
  default     = ""
}

variable "deploy_sample_workload" {
  description = "Whether to deploy the verified sample sandboxed workload"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
