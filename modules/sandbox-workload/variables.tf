variable "name" {
  description = "Workload name: used for the Deployment, ServiceAccount, Service and the `app` label"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$", var.name))
    error_message = "Workload names must be lowercase DNS-1123 labels of at most 40 characters."
  }
}

variable "config" {
  description = "Workload definition (from apps/<name>.yaml, var.workloads, or a direct module call)"
  type = object({
    mode              = string               # "isolated" or "confidential"
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

  validation {
    condition     = contains(["isolated", "confidential"], var.config.mode)
    error_message = "mode must be 'isolated' or 'confidential'."
  }

  validation {
    condition     = !var.config.manage_deployment || try(length(var.config.image) > 0, false)
    error_message = "image is required when manage_deployment is true."
  }

  validation {
    condition     = var.config.replicas >= 0 && var.config.replicas <= 50
    error_message = "replicas must be between 0 and 50."
  }

  validation {
    condition     = !var.config.allow_ingress || var.config.port != null
    error_message = "allow_ingress requires port to be set."
  }

  validation {
    condition = var.config.mode != "confidential" || (
      length(var.config.expected_pcr17) > 0 &&
      alltrue([for p in var.config.expected_pcr17 : can(regex("^[0-9a-fA-F]{96}$", p))]) &&
      !var.config.kms_decrypt
    )
    error_message = "Confidential workloads need at least one 96-hex-character expected_pcr17, and kms_decrypt is not allowed (KMS access is attestation-gated)."
  }

  validation {
    condition = var.config.mode != "confidential" || !var.config.manage_deployment || (
      can(regex("@sha256:[0-9a-f]{64}$", var.config.image)) &&
      try(length(var.config.cedar_policy_base64) > 0, false) &&
      var.config.run_as_group != null
    )
    error_message = "Managed confidential workloads need an image pinned by @sha256 digest, cedar_policy_base64, and run_as_group. Without an explicit run_as_group, genpolicy assumes group 0 but the runtime uses the image's group for the user, and the Cedar policy rejects the container."
  }
}

variable "namespace" {
  description = "Namespace to deploy into"
  type        = string
}

variable "sandbox_modes" {
  description = "Sandbox modes enabled on the cluster"
  type        = list(string)
}

variable "cluster_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "partition" {
  type    = string
  default = "aws"
}

variable "kms_key_arn" {
  description = "Platform KMS key ARN, used only for kms_decrypt on isolated workloads"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
