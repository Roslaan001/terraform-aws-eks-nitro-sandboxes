# Terraform Test: apps stack (YAML loading, outputs) and modules/sandbox-workload (resources, KMS key,
# validation). Mocked providers; no AWS calls. Uses tests/fixtures/apps instead of this directory's apps.

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
  mock_data "aws_eks_cluster" {
    defaults = {
      name                  = "test-nitro-eks"
      endpoint              = "https://example.eks.amazonaws.com"
      certificate_authority = [{ data = "dGVzdA==" }]
    }
  }
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/platform"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/mock"
      key_id = "mock"
    }
  }
}
mock_provider "kubernetes" {}

variables {
  cluster_name = "test-nitro-eks"
  apps_dir     = "tests/fixtures/apps"
  workloads = {
    agent = {
      mode            = "isolated"
      image           = "public.ecr.aws/docker/library/busybox:1.36.1"
      command         = ["/bin/sh", "-c", "sleep 3600"]
      iam_policy_arns = ["arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"]
      kms_decrypt     = true
    }
    model-api = {
      mode                = "confidential"
      image               = "public.ecr.aws/nginx/nginx-unprivileged@sha256:a77f1af2603df07bbf73221721393ab5d687de83462106937143e86460514f1e"
      port                = 8080
      allow_ingress       = true
      env                 = { LOG_LEVEL = "info" }
      run_as_user         = 101
      run_as_group        = 101
      cedar_policy_base64 = "H4sIAAAAAAAC/0tLTQEAAP//AwBCv7bdBAAAAA=="
      expected_pcr17 = [
        "111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111",
        "222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222",
      ]
    }
    gitops-app = {
      mode              = "confidential"
      manage_deployment = false
      expected_pcr17    = ["333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333"]
    }
  }
}

# ---------------- Apps stack: loading, merging, outputs ----------------

run "stack_loads_files_and_variable" {
  command = apply

  assert {
    condition     = sort(keys(output.workload_role_arns)) == sort(["agent", "model-api", "gitops-app", "fixture-web"])
    error_message = "Apps from var.workloads and apps_dir/*.yaml must all get a role."
  }

  assert {
    condition     = sort(keys(output.workload_kms_key_arns)) == sort(["model-api", "gitops-app"])
    error_message = "Each confidential app (managed or not) gets its own KMS key; isolated apps don't."
  }

  assert {
    condition     = contains(keys(output.workload_manifests), "fixture-web") && contains(keys(output.workload_manifests), "model-api") && !contains(keys(output.workload_manifests), "gitops-app")
    error_message = "Only Terraform-managed deployments have a rendered manifest."
  }

  assert {
    condition     = yamldecode(output.workload_manifests["fixture-web"]).spec.template.spec.containers[0].securityContext.runAsUser == 101
    error_message = "YAML values must reach the deployment."
  }

  assert {
    condition     = yamldecode(output.workload_manifests["model-api"]).spec.template.spec.enableServiceLinks == false && yamldecode(output.workload_manifests["model-api"]).spec.template.spec.containers[0].securityContext.runAsGroup == 101
    error_message = "The rendered manifest must match the deployed pod spec, including runAsGroup."
  }
}

run "remove_all_apps" {
  command = plan

  variables {
    workloads = {}
    apps_dir  = "tests/fixtures/no-apps"
  }

  assert {
    condition     = length(output.workload_role_arns) == 0 && length(output.workload_kms_key_arns) == 0
    error_message = "Removing every app must plan cleanly and remove everything."
  }
}

run "reject_duplicate_names" {
  command = plan

  variables {
    workloads = { fixture-web = { mode = "isolated", image = "x" } }
  }

  expect_failures = [output.workload_role_arns]
}

# ---------------- Module: resources per app ----------------

run "module_managed_isolated" {
  command = apply

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "web"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["isolated"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/platform"
    config = {
      mode            = "isolated"
      image           = "public.ecr.aws/nginx/nginx-unprivileged:alpine"
      port            = 8080
      allow_ingress   = true
      kms_decrypt     = true
      iam_policy_arns = ["arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"]
    }
  }

  assert {
    condition     = aws_iam_role.this.name == "test-nitro-eks-web" && strcontains(aws_iam_role.this.assume_role_policy, "pods.eks.amazonaws.com") && strcontains(aws_iam_role.this.assume_role_policy, "cluster/test-nitro-eks")
    error_message = "Each app role must be <cluster>-<app> and trust only EKS Pod Identity for this cluster."
  }

  assert {
    condition     = length(aws_kms_key.this) == 0
    error_message = "Isolated apps don't get their own KMS key."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.base.policy, "key/platform")
    error_message = "kms_decrypt must grant an isolated app access to the platform key."
  }

  assert {
    condition     = kubernetes_deployment_v1.this[0].spec[0].template[0].spec[0].runtime_class_name == "isolated-sandbox"
    error_message = "Isolated app must use the isolated-sandbox RuntimeClass."
  }

  assert {
    condition     = kubernetes_deployment_v1.this[0].spec[0].template[0].spec[0].container[0].security_context[0].seccomp_profile[0].type == "RuntimeDefault" && kubernetes_deployment_v1.this[0].spec[0].template[0].spec[0].container[0].security_context[0].run_as_user == "10001"
    error_message = "Apps must satisfy the restricted Pod Security Standard."
  }

  assert {
    condition     = length(kubernetes_service_v1.this) == 1 && length(kubernetes_network_policy_v1.ingress) == 1 && length(aws_iam_role_policy_attachment.this) == 1
    error_message = "port, allow_ingress and iam_policy_arns must create a Service, NetworkPolicy and attachment."
  }
}

run "module_confidential_own_key" {
  command = apply

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "model-api"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["confidential"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/platform"
    config = {
      mode                = "confidential"
      image               = "public.ecr.aws/nginx/nginx-unprivileged@sha256:a77f1af2603df07bbf73221721393ab5d687de83462106937143e86460514f1e"
      run_as_user         = 101
      run_as_group        = 101
      cedar_policy_base64 = "x"
      expected_pcr17 = [
        "111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111",
        "222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222",
      ]
    }
  }

  assert {
    condition     = length(aws_kms_key.this) == 1 && aws_kms_alias.this[0].name == "alias/test-nitro-eks-model-api"
    error_message = "A confidential app must get its own KMS key and alias."
  }

  assert {
    condition = one([for s in jsondecode(aws_kms_key.this[0].policy).Statement : s if s.Sid == "DenyWorkloadMismatchedPCR17"]).Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR17"] == [
      "111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111",
      "222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222",
    ]
    error_message = "The PCR17 Deny must list every accepted PCR17 value."
  }

  assert {
    condition     = one([for s in jsondecode(aws_kms_key.this[0].policy).Statement : s if s.Sid == "DenyWorkloadMismatchedPCR8"]).Condition.StringNotEqualsIgnoreCase["kms:RecipientAttestation:PCR8:ServiceName"] == "eks.amazonaws.com"
    error_message = "The PCR8 Deny must require eks.amazonaws.com."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_kms_key.this[0].policy).Statement : s.Principal.AWS == aws_iam_role.this.arn if s.Sid != "EnableIAMUserPermissions"])
    error_message = "The key's Deny/Allow statements must be bound to this app's own role."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.base.policy, "kms:")
    error_message = "Confidential apps get no IAM KMS grant; access is only through their attestation-gated key."
  }
}

run "module_identity_slot_only" {
  command = apply

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "gitops-app"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["isolated", "confidential"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "arn:aws:kms:us-east-1:123456789012:key/platform"
    config = {
      mode              = "confidential"
      manage_deployment = false
      port              = 8080
      allow_ingress     = true
      expected_pcr17    = ["333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333333"]
    }
  }

  assert {
    condition     = length(kubernetes_deployment_v1.this) == 0 && length(kubernetes_service_v1.this) == 0
    error_message = "manage_deployment = false must not create a Deployment or Service."
  }

  assert {
    condition     = kubernetes_service_account_v1.this.metadata[0].name == "gitops-app" && aws_eks_pod_identity_association.this.service_account == "gitops-app" && length(aws_kms_key.this) == 1
    error_message = "The identity slot must create the ServiceAccount, Pod Identity association and (confidential) KMS key."
  }

  assert {
    condition     = kubernetes_network_policy_v1.ingress[0].spec[0].pod_selector[0].match_labels["app"] == "gitops-app"
    error_message = "allow_ingress must select pods labelled app=<name>."
  }

  assert {
    condition     = output.manifest == null
    error_message = "No manifest is rendered for unmanaged deployments."
  }
}

# ---------------- Module: validation ----------------

run "reject_unpinned_confidential_image" {
  command = plan

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "bad"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["confidential"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "x"
    config = {
      mode                = "confidential"
      image               = "public.ecr.aws/nginx/nginx-unprivileged:latest"
      cedar_policy_base64 = "x"
      run_as_group        = 101
      expected_pcr17      = ["111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"]
    }
  }

  expect_failures = [var.config]
}

run "reject_confidential_without_run_as_group" {
  command = plan

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "bad"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["confidential"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "x"
    config = {
      mode                = "confidential"
      image               = "public.ecr.aws/nginx/nginx-unprivileged@sha256:a77f1af2603df07bbf73221721393ab5d687de83462106937143e86460514f1e"
      cedar_policy_base64 = "x"
      expected_pcr17      = ["111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"]
    }
  }

  expect_failures = [var.config]
}

run "reject_confidential_without_pcr17" {
  command = plan

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "bad"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["confidential"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "x"
    config = {
      mode              = "confidential"
      manage_deployment = false
    }
  }

  expect_failures = [var.config]
}

run "reject_managed_without_image" {
  command = plan

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "bad"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["isolated"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "x"
    config = {
      mode = "isolated"
    }
  }

  expect_failures = [var.config]
}

run "reject_mode_not_enabled" {
  command = plan

  module {
    source = "../modules/sandbox-workload"
  }

  variables {
    name          = "secret"
    namespace     = "nitro-sandboxes"
    sandbox_modes = ["isolated"]
    aws_region    = "us-east-1"
    account_id    = "123456789012"
    kms_key_arn   = "x"
    config = {
      mode              = "confidential"
      manage_deployment = false
      expected_pcr17    = ["111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"]
    }
  }

  expect_failures = [kubernetes_service_account_v1.this]
}
