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
        }
      ],
      # Confidential Sandbox Attestation statements:
      # EnableIAMUserPermissions (account root) delegates KMS authorization to IAM policies, so the
      # gated Allow below is NOT the only authorization path. The two explicit Deny statements are the
      # critical attestation controls: they override any Allow (key policy, IAM policy, or grant).
      # Explicitly deny decryption if EITHER PCR17 or PCR8 fails to match the expected attestation values.
      # Separate statements ensure independent evaluation (logical OR across Deny statements).
      contains(var.sandbox_modes, "confidential") ? [
        {
          Sid    = "DenyConfidentialWorkloadMismatchedPCR17"
          Effect = "Deny"
          Principal = {
            AWS = aws_iam_role.workload.arn
          }
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey"
          ]
          Resource = "*"
          Condition = {
            StringNotEqualsIgnoreCase = {
              "kms:RecipientAttestation:PCR17" = var.confidential_expected_pcr17
            }
          }
        },
        {
          Sid    = "DenyConfidentialWorkloadMismatchedPCR8"
          Effect = "Deny"
          Principal = {
            AWS = aws_iam_role.workload.arn
          }
          Action = [
            "kms:Decrypt",
            "kms:GenerateDataKey"
          ]
          Resource = "*"
          Condition = {
            StringNotEqualsIgnoreCase = {
              "kms:RecipientAttestation:PCR8:ServiceName" = "eks.amazonaws.com"
            }
          }
        },
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
              "kms:RecipientAttestation:PCR17"            = var.confidential_expected_pcr17
              "kms:RecipientAttestation:PCR8:ServiceName" = "eks.amazonaws.com"
            }
          }
        }
      ] : [],
      # When confidential mode is NOT enabled (pure isolated mode), allow standard workload decrypt
      !contains(var.sandbox_modes, "confidential") && contains(var.sandbox_modes, "isolated") ? [
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
  name          = "alias/${var.cluster_name}-key"
  target_key_id = aws_kms_key.eks.key_id
}
