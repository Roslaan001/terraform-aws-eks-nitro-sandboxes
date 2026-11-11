# Terraform Test: EKS Nitro Sandbox Validation

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
    }
  }
}
mock_provider "kubernetes" {}

variables {
  cluster_name           = "test-nitro-eks"
  aws_region             = "us-east-1"
  sandbox_modes          = ["isolated", "confidential"]
  enable_auto_mode       = true
  deploy_sample_workload = true
  vpc_cidr               = "10.0.0.0/16"
  availability_zones     = ["us-east-1a", "us-east-1b"]
}

run "validate_eks_auto_mode_and_sandbox_config" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.compute_config[0].enabled == true
    error_message = "EKS Auto Mode compute_config must be enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.kubernetes_network_config[0].elastic_load_balancing[0].enabled == true
    error_message = "EKS Auto Mode elastic load balancing must be enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.storage_config[0].block_storage[0].enabled == true
    error_message = "EKS Auto Mode block storage must be enabled."
  }

  assert {
    condition     = aws_eks_cluster.this.bootstrap_self_managed_addons == false
    error_message = "bootstrap_self_managed_addons must be false for Auto Mode."
  }

  assert {
    condition     = contains(aws_eks_cluster.this.compute_config[0].node_pools, "general-purpose")
    error_message = "General-purpose node pool must be configured for Auto Mode."
  }

  assert {
    condition     = kubernetes_namespace_v1.sandbox.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Sandbox namespace must enforce restricted Pod Security Standards."
  }

  assert {
    condition     = kubernetes_deployment_v1.isolated_workload[0].spec[0].template[0].spec[0].runtime_class_name == "isolated-sandbox"
    error_message = "Isolated workload must reference built-in 'isolated-sandbox' RuntimeClass."
  }
}

run "validate_confidential_mode_configuration" {
  command = plan

  variables {
    sandbox_modes               = ["confidential"]
    confidential_expected_pcr17 = "b4a3a60f9e9cf2ec0b4e2f9d6a7d5b8e9f2a4c1d3e5f7a9b0c2d4e6f8a1b3c5d"
  }

  assert {
    condition     = contains(var.sandbox_modes, "confidential")
    error_message = "Sandbox modes must contain 'confidential'."
  }

  assert {
    condition     = kubernetes_deployment_v1.confidential_workload[0].spec[0].template[0].spec[0].runtime_class_name == "confidential-sandbox"
    error_message = "Confidential workload must reference built-in 'confidential-sandbox' RuntimeClass."
  }

  assert {
    condition     = kubernetes_deployment_v1.confidential_workload[0].spec[0].template[0].metadata[0].annotations["sandbox.amazonaws.com/policy"] != ""
    error_message = "Confidential workload must attach Cedar policy annotation."
  }
}
