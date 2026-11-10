output "instance_id" {
  description = "ID of the Nitro Sandbox host EC2 instance"
  value       = aws_instance.nitro_host.id
}

output "instance_arn" {
  description = "ARN of the Nitro Sandbox host EC2 instance"
  value       = aws_instance.nitro_host.arn
}

output "private_ip" {
  description = "Private IP address of the Nitro host instance"
  value       = aws_instance.nitro_host.private_ip
}

output "security_group_id" {
  description = "Security group ID for the Nitro host"
  value       = aws_security_group.nitro_host.id
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the instance profile"
  value       = aws_iam_role.nitro_host.arn
}

output "nitro_enclaves_enabled" {
  description = "Whether Nitro Enclaves hardware isolation is enabled on the instance"
  value       = var.enable_nitro_enclaves
}
