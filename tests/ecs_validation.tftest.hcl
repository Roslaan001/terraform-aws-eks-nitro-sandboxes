# Terraform Test: ECS Nitro Sandbox Module Validation

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }
}

variables {
  cluster_name       = "test-nitro-ecs"
  environment        = "test"
  vpc_id             = "vpc-12345678"
  private_subnet_ids = ["subnet-11111111", "subnet-22222222"]
  isolation_mode     = "ISOLATED_SANDBOX"
}

run "validate_ecs_cluster_and_task_settings" {
  command = plan

  module {
    source = "./modules/ecs"
  }

  assert {
    condition     = contains([for s in aws_ecs_cluster.this.setting : s.value], "enabled")
    error_message = "Container Insights must be enabled on the ECS cluster."
  }

  assert {
    condition     = aws_ecs_task_definition.standard.network_mode == "awsvpc"
    error_message = "Task definition network mode must be awsvpc."
  }
}
