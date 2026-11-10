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
    error_message = "EKS Auto Mode must be enabled for native Nitro Sandbox provisioning."
  }

  assert {
    condition     = contains(aws_eks_cluster.this.compute_config[0].node_pools, "general-purpose")
    error_message = "General-purpose node pool must be configured for Auto Mode."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API_AND_CONFIG_MAP"
    error_message = "EKS Cluster access config must support API authentication mode."
  }

  assert {
    condition     = kubernetes_runtime_class_v1.isolated_sandbox[0].handler == "isolated-sandbox"
    error_message = "Kubernetes RuntimeClass handler must be 'isolated-sandbox'."
  }

  assert {
    condition     = kubernetes_runtime_class_v1.confidential_sandbox[0].handler == "confidential-sandbox"
    error_message = "Kubernetes RuntimeClass handler must be 'confidential-sandbox'."
  }

  assert {
    condition     = kubernetes_namespace_v1.sandbox.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted"
    error_message = "Sandbox namespace must enforce restricted Pod Security Standards."
  }
}

run "validate_confidential_mode_configuration" {
  command = plan

  variables {
    sandbox_modes                      = ["confidential"]
    confidential_expected_image_digest = "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
  }

  assert {
    condition     = contains(var.sandbox_modes, "confidential")
    error_message = "Sandbox modes must contain 'confidential'."
  }

  assert {
    condition     = length(kubernetes_runtime_class_v1.confidential_sandbox) == 1
    error_message = "Confidential sandbox runtime class must be created."
  }
}
