resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.eks.arn

  tags = var.tags
}

resource "aws_eks_cluster" "this" {
  name                          = var.cluster_name
  version                       = var.kubernetes_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = var.enable_auto_mode ? false : true

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    #trivy:ignore:AVD-AWS-0040:Public cluster access is configurable for external kubectl access
    #trivy:ignore:aws-eks-no-public-cluster-access:Configurable for external kubectl access
    endpoint_public_access = var.cluster_endpoint_public_access
    #trivy:ignore:AVD-AWS-0041:Public CIDRs configurable via variable for external kubectl access
    #trivy:ignore:aws-eks-no-public-cluster-access-to-cidr:Configurable for external kubectl access
    public_access_cidrs = var.cluster_endpoint_public_access_cidrs
    security_group_ids  = [aws_security_group.cluster.id]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  dynamic "compute_config" {
    for_each = var.enable_auto_mode ? [1] : []
    content {
      enabled       = true
      node_pools    = var.node_pools
      node_role_arn = aws_iam_role.node.arn
    }
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = var.enable_auto_mode
    }
  }

  storage_config {
    block_storage {
      enabled = var.enable_auto_mode
    }
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_iam_role_policy_attachment.cluster_compute,
    aws_iam_role_policy_attachment.cluster_block_storage,
    aws_iam_role_policy_attachment.cluster_load_balancing,
    aws_iam_role_policy_attachment.cluster_networking,
    aws_cloudwatch_log_group.eks
  ]

  tags = var.tags
}

# EKS Access Entry for Auto Mode Worker Nodes (managed natively when enable_auto_mode is true)
resource "aws_eks_access_entry" "node" {
  count         = var.enable_auto_mode ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.this]
}

# EKS Access Entry for Deployer / Administrator (bootstrapped natively when enable_auto_mode is true)
resource "aws_eks_access_entry" "admin" {
  count         = var.enable_auto_mode ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_caller_identity.current.arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_access_policy_association" "admin" {
  count         = var.enable_auto_mode ? 0 : 1
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterAdminPolicy"
  principal_arn = data.aws_caller_identity.current.arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# EKS Pod Identity Association for Sandboxed Workloads
resource "aws_eks_pod_identity_association" "workload" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = var.sandbox_namespace
  service_account = "sandbox-workload-sa"
  role_arn        = aws_iam_role.workload.arn

  depends_on = [
    aws_eks_cluster.this,
    kubernetes_namespace_v1.sandbox,
    kubernetes_service_account_v1.workload
  ]
}
