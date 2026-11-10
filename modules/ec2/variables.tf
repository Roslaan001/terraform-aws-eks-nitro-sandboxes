variable "instance_name" {
  description = "Name tag for the EC2 Nitro Sandbox host instance"
  type        = string
  default     = "nitro-sandbox-host"
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "ID of the VPC where the EC2 instance will be deployed"
  type        = string
}

variable "subnet_id" {
  description = "ID of the private subnet where the EC2 instance will reside"
  type        = string
}

variable "instance_type" {
  description = "Nitro-based EC2 instance type supporting Nitro Enclaves and MicroVMs (e.g. c6i.xlarge, m6i.xlarge, c7g.xlarge)"
  type        = string
  default     = "c6i.xlarge"

  validation {
    condition     = can(regex("^(c6i|m6i|r6i|c7g|m7g|r7g|c6a|m6a|r6a)\\.", var.instance_type))
    error_message = "instance_type must be a Nitro-based family (c6i, m6i, r6i, c7g, m7g, r7g, c6a, m6a, r6a) that supports Nitro hypervisor virtualization."
  }
}

variable "enable_nitro_enclaves" {
  description = "Whether to enable Nitro Enclaves / hardware-enforced sandbox option on the EC2 instance"
  type        = bool
  default     = true
}

variable "root_volume_size" {
  description = "Size of the encrypted root EBS volume in GiB"
  type        = number
  default     = 50

  validation {
    condition     = var.root_volume_size >= 30 && var.root_volume_size <= 500
    error_message = "root_volume_size must be between 30 and 500 GiB."
  }
}

variable "tags" {
  description = "Tags to apply to all EC2 resources"
  type        = map(string)
  default     = {}
}
