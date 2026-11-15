variable "name" {
  description = "Workload name: used for the Deployment, ServiceAccount, Service and the `app` label"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$", var.name))
    error_message = "Workload names must be lowercase DNS-1123 labels of at most 40 characters."
  }
}

# --- Workload Configuration (Top-level inputs for direct HCL callers) ---

variable "mode" {
  description = "Sandbox mode: 'isolated' (microVM hardware isolation) or 'confidential' (microVM + Cedar policy & KMS recipient attestation)"
  type        = string
  default     = "isolated"

  validation {
    condition     = contains(["isolated", "confidential"], var.mode)
    error_message = "mode must be 'isolated' or 'confidential'."
  }
}

variable "manage_deployment" {
  description = "Whether Terraform manages the Deployment and Service (true), or only the identity slot (false: IAM, ServiceAccount, Pod Identity)"
  type        = bool
  default     = true
}

variable "image" {
  description = "Container image (required if manage_deployment = true; pinned by @sha256 digest for confidential workloads)"
  type        = string
  default     = null

  validation {
    condition     = var.image == null || length(var.image) > 0
    error_message = "image cannot be empty if specified."
  }
}

variable "replicas" {
  description = "Number of pod replicas"
  type        = number
  default     = 1

  validation {
    condition     = var.replicas >= 0 && var.replicas <= 50
    error_message = "replicas must be between 0 and 50."
  }
}

variable "command" {
  description = "Container entrypoint override"
  type        = list(string)
  default     = null
}

variable "args" {
  description = "Container arguments override"
  type        = list(string)
  default     = null
}

variable "env" {
  description = "Environment variables for the container"
  type        = map(string)
  default     = {}
}

variable "port" {
  description = "Container port; creates a ClusterIP Service (managed deployments)"
  type        = number
  default     = null
}

variable "allow_ingress" {
  description = "NetworkPolicy: allow ingress to `port` on pods labelled app=<name>"
  type        = bool
  default     = false
}

variable "cpu_request" {
  description = "CPU request"
  type        = string
  default     = "100m"
}

variable "memory_request" {
  description = "Memory request"
  type        = string
  default     = "128Mi"
}

variable "cpu_limit" {
  description = "CPU limit"
  type        = string
  default     = "500m"
}

variable "memory_limit" {
  description = "Memory limit"
  type        = string
  default     = "512Mi"
}

variable "run_as_user" {
  description = "UID to run container as (must be non-root)"
  type        = number
  default     = 10001
}

variable "run_as_group" {
  description = "GID to run container as (required for managed confidential workloads)"
  type        = number
  default     = null
}

variable "iam_policy_arns" {
  description = "List of IAM policy ARNs to attach to the workload's Pod Identity role"
  type        = list(string)
  default     = []
}

variable "iam_policy_json" {
  description = "Custom inline IAM policy JSON for the workload's Pod Identity role"
  type        = string
  default     = null
}

variable "kms_decrypt" {
  description = "Allow workload role to decrypt using platform KMS key (isolated mode only)"
  type        = bool
  default     = false
}

variable "cedar_policy_base64" {
  description = "Base64-encoded Cedar policy from eks-nitro-sandbox-genpolicy (confidential mode)"
  type        = string
  default     = null
}

variable "expected_pcr17" {
  description = "List of expected 96-hex PCR17 measurements for KMS recipient attestation (confidential mode)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.expected_pcr17 : can(regex("^[0-9a-fA-F]{96}$", p))])
    error_message = "expected_pcr17 entries must be 96-hex-character strings."
  }
}

# --- Optional Object Input (Useful when loading workloads from YAML/JSON files) ---

variable "config" {
  description = "Optional workload definition object (from apps/<name>.yaml, var.workloads, or a direct module call). If provided, takes precedence over top-level variables."
  type = object({
    mode              = optional(string, "isolated")
    manage_deployment = optional(bool, true) # false: Terraform creates only the identity slot; you deploy with kubectl/Helm/GitOps
    image             = optional(string)     # required when manage_deployment = true
    replicas          = optional(number, 1)
    command           = optional(list(string))
    args              = optional(list(string))
    env               = optional(map(string), {})

    port          = optional(number)      # container port; creates a ClusterIP Service (managed deployments)
    allow_ingress = optional(bool, false) # NetworkPolicy: allow ingress to `port` on pods labelled app=<name>

    cpu_request    = optional(string, "100m")
    memory_request = optional(string, "128Mi")
    cpu_limit      = optional(string, "500m")
    memory_limit   = optional(string, "512Mi")
    run_as_user    = optional(number, 10001)
    run_as_group   = optional(number) # required for managed confidential workloads (see validation)

    iam_policy_arns = optional(list(string), [])
    iam_policy_json = optional(string)
    kms_decrypt     = optional(bool, false) # isolated only

    cedar_policy_base64 = optional(string)           # confidential + managed: genpolicy output
    expected_pcr17      = optional(list(string), []) # confidential: accepted PCR17 values (several during a rollout)
  })
  default = null

  validation {
    condition     = var.config == null || contains(["isolated", "confidential"], coalesce(var.config.mode, "isolated"))
    error_message = "mode must be 'isolated' or 'confidential'."
  }

  validation {
    condition     = var.config == null || !coalesce(var.config.manage_deployment, true) || try(length(var.config.image) > 0, false)
    error_message = "image is required when manage_deployment is true."
  }

  validation {
    condition     = var.config == null || (coalesce(var.config.replicas, 1) >= 0 && coalesce(var.config.replicas, 1) <= 50)
    error_message = "replicas must be between 0 and 50."
  }

  validation {
    condition     = var.config == null || !coalesce(var.config.allow_ingress, false) || var.config.port != null
    error_message = "allow_ingress requires port to be set."
  }

  validation {
    condition = var.config == null || coalesce(var.config.mode, "isolated") != "confidential" || (
      length(coalesce(var.config.expected_pcr17, [])) > 0 &&
      alltrue([for p in coalesce(var.config.expected_pcr17, []) : can(regex("^[0-9a-fA-F]{96}$", p))]) &&
      !coalesce(var.config.kms_decrypt, false)
    )
    error_message = "Confidential workloads need at least one 96-hex-character expected_pcr17, and kms_decrypt is not allowed (KMS access is attestation-gated)."
  }

  validation {
    condition = var.config == null || coalesce(var.config.mode, "isolated") != "confidential" || !coalesce(var.config.manage_deployment, true) || (
      can(regex("@sha256:[0-9a-f]{64}$", var.config.image)) &&
      try(length(var.config.cedar_policy_base64) > 0, false) &&
      var.config.run_as_group != null
    )
    error_message = "Managed confidential workloads need an image pinned by @sha256 digest, cedar_policy_base64, and run_as_group. Without an explicit run_as_group, genpolicy assumes group 0 but the runtime uses the image's group for the user, and the Cedar policy rejects the container."
  }
}

# --- Infrastructure & Environment Context ---

variable "namespace" {
  description = "Namespace to deploy into"
  type        = string
}

variable "sandbox_modes" {
  description = "Sandbox modes enabled on the cluster"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "aws_region" {
  description = "AWS region (defaults to the AWS provider's current region)"
  type        = string
  default     = null
}

variable "account_id" {
  description = "AWS account ID (defaults to the current caller identity)"
  type        = string
  default     = null
}

variable "partition" {
  description = "AWS partition ('aws', 'aws-cn', 'aws-us-gov')"
  type        = string
  default     = "aws"
}

variable "kms_key_arn" {
  description = "Platform KMS key ARN, required only when kms_decrypt = true on isolated workloads"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
