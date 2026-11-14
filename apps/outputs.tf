output "workload_role_arns" {
  description = "IAM role ARN per app (assumed through EKS Pod Identity)"
  value       = { for k, m in module.workload : k => m.role_arn }

  precondition {
    condition     = length(local.duplicate_workload_names) == 0
    error_message = "Apps defined both as <name>.yaml and in var.workloads: ${join(", ", local.duplicate_workload_names)}."
  }
}

output "workload_service_accounts" {
  description = "ServiceAccount per app; pods must use it (and label app=<name>) to get the app's role and NetworkPolicy"
  value       = { for k, m in module.workload : k => m.service_account }
}

output "workload_kms_key_arns" {
  description = "Each confidential app's own KMS key: encrypt its container images with this. Only the attested guest can decrypt; the app's own SDK Decrypt/GenerateDataKey calls are explicitly denied."
  value       = { for k, m in module.workload : k => m.kms_key_arn if m.kms_key_arn != null }
}

output "workload_manifests" {
  description = "Rendered Deployment manifest (YAML) per Terraform-managed app. For confidential apps, run eks-nitro-sandbox-genpolicy against this to get cedar_policy_base64 and expected_pcr17."
  value       = { for k, m in module.workload : k => yamlencode(m.manifest) if m.manifest != null }
}
