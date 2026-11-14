# 1. Namespace with Pod Security Standards (Restricted)
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

# 2. Workload Service Account for EKS Pod Identity
resource "kubernetes_service_account_v1" "workload" {
  metadata {
    name      = "sandbox-workload-sa"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.workload.arn
    }
  }
}

# 3. Network Policy: Default Deny All Ingress and Egress
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

# 4. Network Policy: Allow Egress to DNS and AWS APIs / ECR / KMS (HTTPS)
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

# 5. Network Policy: Allow HTTP Ingress within Cluster
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

# 6. Sample Isolated Sandboxed Workload
# Uses EKS Auto Mode's built-in 'isolated-sandbox' RuntimeClass
resource "kubernetes_deployment_v1" "isolated_workload" {
  count = var.deploy_sample_workload && contains(var.sandbox_modes, "isolated") ? 1 : 0

  metadata {
    name      = "nitro-sandbox-isolated"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name

    labels = {
      app                           = "nitro-sandbox-sample"
      "sandbox.aws.amazon.com/mode" = "isolated"
    }
  }

  spec {
    replicas = var.sample_workload_replicas

    selector {
      match_labels = {
        app                           = "nitro-sandbox-sample"
        "sandbox.aws.amazon.com/mode" = "isolated"
      }
    }

    template {
      metadata {
        labels = {
          app                           = "nitro-sandbox-sample"
          "sandbox.aws.amazon.com/mode" = "isolated"
        }
      }

      spec {
        # Directly reference the built-in EKS Auto Mode isolated RuntimeClass
        runtime_class_name   = "isolated-sandbox"
        service_account_name = kubernetes_service_account_v1.workload.metadata[0].name

        container {
          name  = "web-app"
          image = var.isolated_workload_image

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
    kubernetes_network_policy_v1.allow_egress,
    kubernetes_network_policy_v1.allow_http
  ]
}

# 7. Sample Confidential Sandboxed Workload
# Uses EKS Auto Mode's built-in 'confidential-sandbox' RuntimeClass
# and enforces Cedar policy via 'sandbox.amazonaws.com/policy' annotation
resource "kubernetes_deployment_v1" "confidential_workload" {
  count = var.deploy_sample_workload && contains(var.sandbox_modes, "confidential") ? 1 : 0

  metadata {
    name      = "nitro-sandbox-confidential"
    namespace = kubernetes_namespace_v1.sandbox.metadata[0].name

    labels = {
      app                           = "nitro-sandbox-sample"
      "sandbox.aws.amazon.com/mode" = "confidential"
    }
  }

  spec {
    replicas = var.sample_workload_replicas

    selector {
      match_labels = {
        app                           = "nitro-sandbox-sample"
        "sandbox.aws.amazon.com/mode" = "confidential"
      }
    }

    template {
      metadata {
        labels = {
          app                           = "nitro-sandbox-sample"
          "sandbox.aws.amazon.com/mode" = "confidential"
        }
        annotations = {
          # Generated Cedar policy attached to confidential pod template
          "sandbox.amazonaws.com/policy" = var.confidential_cedar_policy_base64
        }
      }

      spec {
        # Directly reference the built-in EKS Auto Mode confidential RuntimeClass
        runtime_class_name   = "confidential-sandbox"
        service_account_name = kubernetes_service_account_v1.workload.metadata[0].name

        container {
          name = "web-app"
          # Immutable digest-pinned image for confidential attestation integrity
          image = var.confidential_workload_image

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
