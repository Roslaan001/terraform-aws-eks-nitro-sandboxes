output "cluster_id" {
  description = "ID of the ECS Cluster"
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "Name of the ECS Cluster"
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the ECS Cluster"
  value       = aws_ecs_cluster.this.arn
}

output "task_execution_role_arn" {
  description = "ARN of the task execution IAM role"
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "ARN of the task IAM role"
  value       = aws_iam_role.task.arn
}

output "security_group_id" {
  description = "Security group ID for ECS tasks"
  value       = aws_security_group.ecs_tasks.id
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group for ECS task logs"
  value       = aws_cloudwatch_log_group.ecs.name
}

output "standard_task_definition_arn" {
  description = "ARN of the standard task definition"
  value       = aws_ecs_task_definition.standard.arn
}

output "nitro_task_definition_identifier" {
  description = "Identifier of the Cloud Control Nitro Sandbox task definition if enabled"
  value       = var.enable_cloudcontrol_nitro_task ? aws_cloudcontrolapi_resource.nitro_task_def[0].id : null
}
