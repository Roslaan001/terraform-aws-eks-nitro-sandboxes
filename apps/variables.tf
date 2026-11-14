variable "aws_region" {
  description = "Region of the platform cluster"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment tag (match the platform stack's environment)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the platform EKS cluster (platform/ stack's cluster_name)"
  type        = string
  default     = "nitro-sandbox-eks"
}

variable "namespace" {
  description = "Sandbox namespace created by the platform stack (its sandbox_namespace)"
  type        = string
  default     = "nitro-sandboxes"
}

variable "sandbox_modes" {
  description = "Sandbox modes enabled on the platform (its sandbox_modes); apps may only use these"
  type        = list(string)
  default     = ["isolated", "confidential"]
}

variable "apps_dir" {
  description = "Directory of <name>.yaml app files (default: this directory). Point it elsewhere per environment."
  type        = string
  default     = null
}

variable "workloads" {
  description = <<-EOT
    Optional extra applications, keyed by name, in addition to the <name>.yaml files.
    Same fields as a YAML file; see ../modules/sandbox-workload/variables.tf for types,
    defaults and validation. A name defined both here and as a file is an error.
  EOT
  type        = any
  default     = {}
}

variable "tags" {
  description = "Tags added to each app's IAM role and KMS key"
  type        = map(string)
  default     = {}
}
