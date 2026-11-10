terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Example   = "ec2-nitro-host"
      Project   = "terraform-aws-nitro-sandbox"
      ManagedBy = "Terraform"
    }
  }
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

# Dedicated VPC for EC2 Sandbox demo
resource "aws_vpc" "ec2_vpc" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "ec2-sandbox-vpc"
  }
}

resource "aws_subnet" "ec2_private" {
  vpc_id            = aws_vpc.ec2_vpc.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "ec2-sandbox-private"
  }
}

module "ec2_sandbox" {
  source = "../../modules/ec2"

  instance_name         = "nitro-sandbox-ec2-demo"
  environment           = "dev"
  vpc_id                = aws_vpc.ec2_vpc.id
  subnet_id             = aws_subnet.ec2_private.id
  instance_type         = "c6i.xlarge"
  enable_nitro_enclaves = true
}

output "instance_id" {
  value = module.ec2_sandbox.instance_id
}

output "nitro_enclaves_enabled" {
  value = module.ec2_sandbox.nitro_enclaves_enabled
}

output "ssm_connect_command" {
  value = "aws ssm start-session --target ${module.ec2_sandbox.instance_id}"
}
