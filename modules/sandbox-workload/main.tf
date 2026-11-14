# One Nitro Sandbox workload (used by the apps stack in apps/).
#
# Always created (the "identity slot"): IAM role (EKS Pod Identity trust only), base IAM policy,
# Pod Identity association, ServiceAccount, and, if allow_ingress, an ingress NetworkPolicy.
# Confidential workloads also get their own KMS key, usable only with a matching attestation, i.e. by the
# AWS agent in the guest to decrypt the workload's encrypted container images. The app's own (unattested)
# SDK kms:Decrypt / kms:GenerateDataKey calls to this key are explicitly denied.
# Created only when manage_deployment = true: Deployment and Service.
#
# The caller must configure the kubernetes provider from a data source (not from an aws_eks_cluster
# resource in the same configuration); otherwise the KMS key policy -> role -> cluster chain cycles.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

locals {
  w    = var.config
  mode = var.config.mode

  labels = {
    app                           = var.name
    "sandbox.aws.amazon.com/mode" = local.mode
  }

  # Pod-spec manifest shared by the Deployment and the `manifest` output, so the manifest you
  # run genpolicy against matches what Terraform deploys.
  manifest = local.w.manage_deployment ? {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = var.name, namespace = var.namespace, labels = local.labels }
    spec = {
      replicas = local.w.replicas
      selector = { matchLabels = local.labels }
      template = {
        metadata = { labels = local.labels }
        spec = {
          runtimeClassName   = "${local.mode}-sandbox"
          serviceAccountName = var.name
          enableServiceLinks = false
          containers = [merge(
            {
              name  = var.name
              image = local.w.image
              resources = {
                requests = { cpu = local.w.cpu_request, memory = local.w.memory_request }
                limits   = { cpu = local.w.cpu_limit, memory = local.w.memory_limit }
              }
              securityContext = {
                allowPrivilegeEscalation = false
                runAsNonRoot             = true
                runAsUser                = local.w.run_as_user
                capabilities             = { drop = ["ALL"] }
                seccompProfile           = { type = "RuntimeDefault" }
              }
            },
            local.w.run_as_group == null ? {} : { securityContext = {
              allowPrivilegeEscalation = false
              runAsNonRoot             = true
              runAsUser                = local.w.run_as_user
              runAsGroup               = local.w.run_as_group
              capabilities             = { drop = ["ALL"] }
              seccompProfile           = { type = "RuntimeDefault" }
            } },
            local.w.command == null ? {} : { command = local.w.command },
            local.w.args == null ? {} : { args = local.w.args },
            length(local.w.env) == 0 ? {} : { env = [for n in sort(keys(local.w.env)) : { name = n, value = local.w.env[n] }] },
            local.w.port == null ? {} : { ports = [{ name = "app", containerPort = local.w.port }] }
          )]
        }
      }
    }
  } : null
}

# --- IAM: one role per workload, assumable only through EKS Pod Identity for this cluster ---

resource "aws_iam_role" "this" {
  name        = "${var.cluster_name}-${var.name}"
  description = "Pod Identity role for Nitro Sandbox workload '${var.name}'"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEksAuthToAssumeRoleForPodIdentity"
        Effect    = "Allow"
        Principal = { Service = "pods.eks.amazonaws.com" }
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnEquals    = { "aws:SourceArn" = "arn:${var.partition}:eks:${var.aws_region}:${var.account_id}:cluster/${var.cluster_name}" }
        }
      }
    ]
  })

  tags = merge(var.tags, { Workload = var.name, SandboxMode = local.mode })

  lifecycle {
    precondition {
      condition     = length("${var.cluster_name}-${var.name}") <= 64
      error_message = "IAM role name '${var.cluster_name}-${var.name}' exceeds 64 characters; shorten the workload name."
    }
  }
}

# --- KMS: confidential workloads get their own key ---
# Same structure as the platform key's sample statements: two independent explicit Denies + a gated
# Allow, bound to this workload's role. Negated operators with a list deny when the attested value
# matches none of the entries, and also when no attestation is present. The account-root statement
# keeps the key administrable; the Denies override any IAM Allow it delegates.

resource "aws_kms_key" "this" {
  count = local.mode == "confidential" ? 1 : 0

  description             = "Nitro Sandbox workload '${var.name}': decrypt only with a matching attestation"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:${var.partition}:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "DenyWorkloadMismatchedPCR17"
        Effect    = "Deny"
        Principal = { AWS = aws_iam_role.this.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          StringNotEqualsIgnoreCase = { "kms:RecipientAttestation:PCR17" = local.w.expected_pcr17 }
        }
      },
      {
        Sid       = "DenyWorkloadMismatchedPCR8"
        Effect    = "Deny"
        Principal = { AWS = aws_iam_role.this.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          StringNotEqualsIgnoreCase = { "kms:RecipientAttestation:PCR8:ServiceName" = "eks.amazonaws.com" }
        }
      },
      {
        Sid       = "AllowWorkloadAttested"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.this.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
        Condition = {
          StringEqualsIgnoreCase = {
            "kms:RecipientAttestation:PCR17"            = local.w.expected_pcr17
            "kms:RecipientAttestation:PCR8:ServiceName" = "eks.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Workload = var.name })
}

resource "aws_kms_alias" "this" {
  count = local.mode == "confidential" ? 1 : 0

  name          = "alias/${var.cluster_name}-${var.name}"
  target_key_id = aws_kms_key.this[0].key_id
}

resource "aws_iam_role_policy" "base" {
  name = "sandbox-base"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "AllowCloudWatchLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:${var.partition}:logs:${var.aws_region}:${var.account_id}:log-group:/aws/eks/${var.cluster_name}/sandboxes/*"
        }
      ],
      local.w.kms_decrypt ? [
        {
          Sid      = "AllowPlatformKeyDecrypt"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource = var.kms_key_arn
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy" "custom" {
  count = local.w.iam_policy_json != null ? 1 : 0

  name   = "workload-custom"
  role   = aws_iam_role.this.id
  policy = local.w.iam_policy_json
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(local.w.iam_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.name
  role_arn        = aws_iam_role.this.arn
}

# --- Kubernetes ---
# No depends_on between Kubernetes objects and the IAM / Pod Identity resources: the kubernetes
# provider is configured from aws_eks_cluster, which depends on the KMS key, so such edges create a
# destroy-time cycle when workloads are removed. Restart the Deployment once after a workload's first
# apply so its pods pick up Pod Identity credentials.

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  lifecycle {
    precondition {
      condition     = contains(var.sandbox_modes, local.mode)
      error_message = "Workload '${var.name}' uses mode '${local.mode}', which is not in sandbox_modes."
    }
  }
}

resource "kubernetes_deployment_v1" "this" {
  count = local.w.manage_deployment ? 1 : 0

  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = local.w.replicas

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
        annotations = local.mode == "confidential" ? {
          "sandbox.amazonaws.com/policy" = local.w.cedar_policy_base64
        } : {}
      }

      spec {
        runtime_class_name   = "${local.mode}-sandbox"
        service_account_name = kubernetes_service_account_v1.this.metadata[0].name
        enable_service_links = false # genpolicy pins env vars exactly

        container {
          name    = var.name
          image   = local.w.image
          command = local.w.command
          args    = local.w.args

          dynamic "env" {
            for_each = sort(keys(local.w.env))
            content {
              name  = env.value
              value = local.w.env[env.value]
            }
          }

          dynamic "port" {
            for_each = local.w.port == null ? [] : [local.w.port]
            content {
              name           = "app"
              container_port = port.value
            }
          }

          resources {
            requests = { cpu = local.w.cpu_request, memory = local.w.memory_request }
            limits   = { cpu = local.w.cpu_limit, memory = local.w.memory_limit }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = local.w.run_as_user
            run_as_group               = local.w.run_as_group

            capabilities {
              drop = ["ALL"]
            }

            seccomp_profile {
              type = "RuntimeDefault"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # Allow `kubectl rollout restart` (needed after a workload's first apply) without drift.
    ignore_changes = [spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"]]
  }
}

resource "kubernetes_service_v1" "this" {
  count = local.w.manage_deployment && local.w.port != null ? 1 : 0

  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      name        = "app"
      port        = local.w.port
      target_port = "app"
    }
  }
}

resource "kubernetes_network_policy_v1" "ingress" {
  count = local.w.allow_ingress ? 1 : 0

  metadata {
    name      = "allow-${var.name}-ingress"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { app = var.name }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = tostring(local.w.port)
        protocol = "TCP"
      }
    }
  }
}
