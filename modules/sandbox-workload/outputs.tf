output "role_arn" {
  description = "IAM role assumed by this workload's pods through EKS Pod Identity"
  value       = aws_iam_role.this.arn
}

output "service_account" {
  description = "ServiceAccount your pods must use to get this workload's role"
  value       = kubernetes_service_account_v1.this.metadata[0].name
}

output "manifest" {
  description = "Rendered Deployment manifest (null when manage_deployment = false)"
  value       = local.manifest
}

output "kms_key_arn" {
  description = "This workload's own KMS key for encrypting its container images; only an attested guest can decrypt (confidential only, else null)"
  value       = try(aws_kms_key.this[0].arn, null)
}
