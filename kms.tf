resource "aws_kms_key" "eks" {
  description             = "KMS Customer Managed Key for ${var.cluster_name} secrets encryption and Nitro Sandbox attestation"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "EnableIAMUserPermissions"
          Effect = "Allow"
          Principal = {
            AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          Action   = "kms:*"
          Resource = "*"
        },
        {
          Sid    = "AllowCloudWatchLogs"
          Effect = "Allow"
          Principal = {
            Service = [
              "logs.${var.aws_region}.amazonaws.com",
              "logs.amazonaws.com"
            ]
          }
          Action = [
            "kms:Encrypt*",
            "kms:Decrypt*",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Describe*"
          ]
          Resource = "*"
          Condition = {
            ArnLike = {
              "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
            }
          }
        },
        {
          Sid    = "AllowEKSEnvelopeEncryption"
          Effect = "Allow"
          Principal = {
            AWS = aws_iam_role.cluster.arn
          }
          Action = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:DescribeKey"
          ]
          Resource = "*"
        },
        {
          Sid    = "AllowWorkloadStandardDecrypt"
          Effect = "Allow"
          Principal = {
            AWS = aws_iam_role.workload.arn
          }
          Action = [
            "kms:Decrypt",
            "kms:DescribeKey"
          ]
          Resource = "*"
        }
      ],
      contains(var.sandbox_modes, "confidential") && var.confidential_expected_image_digest != "" ? [
        {
          Sid    = "EnforceNitroAttestationForConfidentialWorkloads"
          Effect = "Allow"
          Principal = {
            AWS = aws_iam_role.workload.arn
          }
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey"
          ]
          Resource = "*"
          Condition = {
            StringEqualsIgnoreCase = {
              "kms:RecipientAttestation:ImageSha384" = var.confidential_expected_image_digest
            }
          }
        }
      ] : []
    )
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-kms-key"
    }
  )
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-kms"
  target_key_id = aws_kms_key.eks.key_id
}
