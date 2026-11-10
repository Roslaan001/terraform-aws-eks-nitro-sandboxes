variable "cluster_name" {
  description = "Name of the ECS Cluster"
  type        = string
  default     = "nitro-sandbox-ecs"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-_]+$", var.cluster_name))
    error_message = "Cluster name must contain only alphanumeric characters, hyphens, and underscores."
  }
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "ID of the VPC where ECS resources will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "task_cpu" {
  description = "CPU units for the task definition (e.g. 512, 1024)"
  type        = string
  default     = "512"
}

variable "task_memory" {
  description = "Memory (in MiB) for the task definition (e.g. 1024, 2048)"
  type        = string
  default     = "1024"
}

variable "container_image" {
  description = "Container image for the sample ECS workload"
  type        = string
  default     = "public.ecr.aws/docker/library/busybox:1.36.1"
}

variable "isolation_mode" {
  description = "Nitro Sandbox execution mode for ECS ('ISOLATED_SANDBOX' or 'CONFIDENTIAL_SANDBOX')"
  type        = string
  default     = "ISOLATED_SANDBOX"

  validation {
    condition     = contains(["ISOLATED_SANDBOX", "CONFIDENTIAL_SANDBOX"], var.isolation_mode)
    error_message = "isolation_mode must be either 'ISOLATED_SANDBOX' or 'CONFIDENTIAL_SANDBOX'."
  }
}

variable "enable_cloudcontrol_nitro_task" {
  description = "Whether to provision the Nitro Sandbox TaskDefinition via AWS Cloud Control API to bridge current terraform-provider-aws schema lag"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all ECS resources"
  type        = map(string)
  default     = {}
}
