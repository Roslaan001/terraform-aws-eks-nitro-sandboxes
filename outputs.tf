output "eks_cluster_name" {
  description = "Amazon EKS Cluster Name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Amazon EKS Control Plane Endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_arn" {
  description = "Amazon EKS Cluster ARN"
  value       = module.eks.cluster_arn
}

output "eks_sandbox_namespace" {
  description = "Namespace where Nitro Sandbox workloads are scheduled"
  value       = module.eks.sandbox_namespace
}

output "eks_sandbox_mode" {
  description = "Active Nitro Sandbox isolation mode ('isolated' or 'confidential')"
  value       = module.eks.sandbox_mode
}

output "eks_runtime_classes" {
  description = "Configured Nitro Sandbox Kubernetes RuntimeClasses"
  value       = module.eks.runtime_classes
}

output "eks_kms_key_arn" {
  description = "KMS Key ARN configured for attestation and envelope encryption"
  value       = module.eks.kms_key_arn
}

output "kubeconfig_update_command" {
  description = "AWS CLI command to configure local kubectl context"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "verify_sandbox_command" {
  description = "Command to verify the deployed sandboxed workload"
  value       = "kubectl get pods -n ${module.eks.sandbox_namespace} -o wide"
}
