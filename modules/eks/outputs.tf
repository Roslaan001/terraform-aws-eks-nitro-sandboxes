output "cluster_name" {
  description = "Name of the Amazon EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the Amazon EKS cluster"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Endpoint URL of the Amazon EKS cluster control plane"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
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

output "cluster_security_group_id" {
  description = "Security Group ID attached to the EKS cluster and nodes"
  value       = aws_security_group.cluster.id
}

output "kms_key_arn" {
  description = "ARN of the KMS Customer Managed Key used for envelope encryption and Nitro attestation"
  value       = aws_kms_key.eks.arn
}

output "kms_key_alias" {
  description = "Alias of the KMS Customer Managed Key"
  value       = aws_kms_alias.eks.name
}

output "node_role_arn" {
  description = "IAM Role ARN assumed by EKS Auto Mode nodes hosting Nitro Sandboxes"
  value       = aws_iam_role.node.arn
}

output "workload_role_arn" {
  description = "IAM Role ARN assumed by sandboxed workloads via EKS Pod Identity"
  value       = aws_iam_role.workload.arn
}

output "sandbox_namespace" {
  description = "Kubernetes namespace configured for Nitro Sandboxes"
  value       = kubernetes_namespace_v1.sandbox.metadata[0].name
}

output "sandbox_mode" {
  description = "Active Nitro Sandbox isolation mode"
  value       = var.sandbox_mode
}

output "runtime_classes" {
  description = "Configured Nitro Sandbox Kubernetes RuntimeClasses"
  value = {
    isolated     = var.manage_runtime_classes ? kubernetes_runtime_class_v1.isolated_sandbox[0].metadata[0].name : "isolated-sandbox"
    confidential = var.manage_runtime_classes ? kubernetes_runtime_class_v1.confidential_sandbox[0].metadata[0].name : "confidential-sandbox"
  }
}

output "sample_deployment_name" {
  description = "Name of the sample sandboxed workload deployment"
  value       = var.deploy_sample_workload ? kubernetes_deployment_v1.sample_workload[0].metadata[0].name : null
}
