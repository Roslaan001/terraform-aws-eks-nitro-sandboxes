output "eks_cluster_name" {
  description = "Amazon EKS Cluster Name"
  value       = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  description = "Amazon EKS Control Plane Endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "eks_cluster_arn" {
  description = "Amazon EKS Cluster ARN"
  value       = aws_eks_cluster.this.arn
}

output "eks_cluster_version" {
  description = "Kubernetes version running on the EKS cluster"
  value       = aws_eks_cluster.this.version
}

output "vpc_id" {
  description = "ID of the dedicated VPC"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs where EKS Auto Mode provisions sandbox nodes"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "eks_kms_key_arn" {
  description = "KMS Key ARN configured for attestation and envelope encryption"
  value       = aws_kms_key.eks.arn
}

output "eks_sandbox_namespace" {
  description = "Namespace where Nitro Sandbox workloads are scheduled"
  value       = kubernetes_namespace_v1.sandbox.metadata[0].name
}

output "eks_sandbox_modes" {
  description = "Enabled Nitro Sandbox isolation modes ('isolated', 'confidential', or both)"
  value       = var.sandbox_modes
}

output "eks_runtime_classes" {
  description = "Configured Nitro Sandbox Kubernetes RuntimeClasses"
  value = {
    for mode in var.sandbox_modes : mode => "${mode}-sandbox"
  }
}

output "sample_deployments" {
  description = "Names of the deployed sample sandboxed workloads"
  value       = [for k, d in kubernetes_deployment_v1.sample_workload : d.metadata[0].name]
}

output "kubeconfig_update_command" {
  description = "AWS CLI command to configure local kubectl context"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}

output "verify_sandbox_command" {
  description = "Command to verify the deployed sandboxed workloads"
  value       = "kubectl get pods -n ${kubernetes_namespace_v1.sandbox.metadata[0].name} -o wide"
}
