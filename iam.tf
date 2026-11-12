data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# 1. Cluster IAM Role for Amazon EKS Auto Mode
resource "aws_iam_role" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-role-"
  description = "IAM role assumed by Amazon EKS control plane"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_compute" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSComputePolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_block_storage_v2" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSBlockStoragePolicyV2"
}

resource "aws_iam_role_policy_attachment" "cluster_load_balancing" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSLoadBalancingPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_networking" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSNetworkingPolicy"
}

# 2. EKS Auto Mode Worker Node IAM Role
resource "aws_iam_role" "node" {
  name_prefix = "${var.cluster_name}-node-role-"
  description = "IAM role assumed by EKS Auto Mode worker nodes hosting Nitro Sandboxes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node_minimal" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_pull" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# 3. Workload Pod Identity IAM Role
resource "aws_iam_role" "workload" {
  name_prefix = "${var.cluster_name}-workload-role-"
  description = "IAM role assumed by sandboxed workloads via EKS Pod Identity"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      },
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_policy" "workload_permissions" {
  name_prefix = "${var.cluster_name}-workload-policy-"
  description = "Least-privilege permissions for sandboxed workloads"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "AllowCloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:*:log-group:/aws/eks/${var.cluster_name}/sandboxes/*"
        }
      ],
      contains(var.sandbox_modes, "confidential") ? [
        {
          Sid      = "AllowKMSDescribeOnly"
          Effect   = "Allow"
          Action   = ["kms:DescribeKey"]
          Resource = aws_kms_key.eks.arn
        }
      ] : [],
      contains(var.sandbox_modes, "confidential") ? [
        {
          Sid    = "AllowKMSDecryptForWorkload"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey"
          ]
          Resource = aws_kms_key.eks.arn
        }
      ] : [],
      !contains(var.sandbox_modes, "confidential") && contains(var.sandbox_modes, "isolated") ? [
        {
          Sid    = "AllowKMSOperations"
          Effect = "Allow"
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey",
            "kms:DescribeKey"
          ]
          Resource = aws_kms_key.eks.arn
        }
      ] : []
    )
  })
}

resource "aws_iam_role_policy_attachment" "workload_attach" {
  role       = aws_iam_role.workload.name
  policy_arn = aws_iam_policy.workload_permissions.arn
}
