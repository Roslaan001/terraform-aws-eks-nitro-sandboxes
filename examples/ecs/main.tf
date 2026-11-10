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
      Example   = "ecs-sandbox"
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

# Isolated VPC for ECS example
resource "aws_vpc" "ecs_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "ecs-sandbox-vpc"
  }
}

resource "aws_subnet" "ecs_private_1" {
  vpc_id            = aws_vpc.ecs_vpc.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "ecs-sandbox-private-1"
  }
}

resource "aws_subnet" "ecs_private_2" {
  vpc_id            = aws_vpc.ecs_vpc.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "ecs-sandbox-private-2"
  }
}

module "ecs_sandbox" {
  source = "../../modules/ecs"

  cluster_name                   = "nitro-sandbox-ecs-demo"
  environment                    = "dev"
  vpc_id                         = aws_vpc.ecs_vpc.id
  private_subnet_ids             = [aws_subnet.ecs_private_1.id, aws_subnet.ecs_private_2.id]
  isolation_mode                 = "ISOLATED_SANDBOX"
  enable_cloudcontrol_nitro_task = false
}

output "ecs_cluster_name" {
  value = module.ecs_sandbox.cluster_name
}

output "standard_task_definition_arn" {
  value = module.ecs_sandbox.standard_task_definition_arn
}
