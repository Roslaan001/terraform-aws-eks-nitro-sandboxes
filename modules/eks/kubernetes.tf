# 1. Kubernetes RuntimeClasses for Nitro Sandboxes
resource "kubernetes_runtime_class_v1" "isolated_sandbox" {
  count = var.manage_runtime_classes ? 1 : 0

  metadata {
    name = "isolated-sandbox"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "sandbox.aws.amazon.com/type"  = "isolated"
    }
  }

  handler = "isolated-sandbox"

  depends_on = [aws_eks_cluster.this]
}

resource "kubernetes_runtime_class_v1" "confidential_sandbox" {
  count = var.manage_runtime_classes ? 1 : 0

  metadata {
    name = "confidential-sandbox"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "sandbox.aws.amazon.com/type"  = "confidential"
    }
  }

  handler = "confidential-sandbox"

  depends_on = [aws_eks_cluster.this]
}

# 2. Namespace with Pod Security Standards (Restricted)
resource "kubernetes_namespace_v1" "sandbox" {
  metadata {
    name = var.sandbox_namespace

    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "security.aws/sandbox-enabled"       = "true"
    }
  }

  depends_on = [aws_eks_cluster.this]
}

# 3. Workload Service Account
resource "kubernetes_service_account_v1" "workload" {
  metadata {
    name      = "sandbox-workload-sa"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.workload.arn
    }
  }
}

# 4. Network Policy: Default Deny All Ingress and Egress
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-sandbox"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# 5. Network Policy: Allow Egress to DNS and AWS APIs / ECR / KMS (HTTPS)
resource "kubernetes_network_policy_v1" "allow_egress" {
  metadata {
    name      = "allow-sandbox-egress"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    # Allow DNS
    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    # Allow HTTPS outbound (AWS APIs, KMS, ECR, CloudWatch)
    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
    }
  }
}

# 6. Network Policy: Allow HTTP Ingress within Cluster
resource "kubernetes_network_policy_v1" "allow_http" {
  metadata {
    name      = "allow-sandbox-http"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "nitro-sandbox-sample"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

# 7. Sample Verified Sandboxed Workload (AWS Web Application)
resource "kubernetes_deployment_v1" "sample_workload" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "nitro-sandbox-sample"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name

    labels = {
      app                           = "nitro-sandbox-sample"
      "sandbox.aws.amazon.com/mode" = var.sandbox_mode
    }
  }

  spec {
    replicas = var.sample_workload_replicas

    selector {
      match_labels = {
        app = "nitro-sandbox-sample"
      }
    }

    template {
      metadata {
        labels = {
          app                           = "nitro-sandbox-sample"
          "sandbox.aws.amazon.com/mode" = var.sandbox_mode
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.workload.metadata[0].name
        runtime_class_name   = var.enable_workload_runtime_class ? (var.sandbox_mode == "confidential" ? "confidential-sandbox" : "isolated-sandbox") : null

        container {
          name  = "web-app"
          image = var.sample_workload_image

          port {
            name           = "http"
            container_port = 8080
          }

          resources {
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 101

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

  depends_on = [
    kubernetes_runtime_class_v1.isolated_sandbox,
    kubernetes_runtime_class_v1.confidential_sandbox,
    kubernetes_network_policy_v1.allow_egress,
    kubernetes_network_policy_v1.allow_http
  ]
}

# 8. ClusterIP Service for Sample Web Workload
resource "kubernetes_service_v1" "sample_workload" {
  count = var.deploy_sample_workload ? 1 : 0

  metadata {
    name      = "nitro-sandbox-service"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name
    labels = {
      app = "nitro-sandbox-sample"
    }
  }

  spec {
    selector = {
      app = "nitro-sandbox-sample"
    }

    port {
      name        = "http"
      port        = 80
      target_port = "8080"
    }

    type = "ClusterIP"
  }
}
