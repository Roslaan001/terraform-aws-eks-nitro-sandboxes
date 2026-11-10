data "aws_partition" "current" {}

# 1. Fetch latest Amazon Linux 2023 AMI optimized for Nitro
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# 2. Security Group: Zero public ingress; HTTPS egress only
resource "aws_security_group" "nitro_host" {
  name_prefix = "${var.instance_name}-sg-"
  description = "Security group for Nitro Sandbox host instance (zero inbound, SSM only)"
  vpc_id      = var.vpc_id

  #trivy:ignore:AVD-AWS-0104:Required for outbound HTTPS for SSM and OS packages
  egress {
    description = "Allow HTTPS outbound for OS packages, SSM, and AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.instance_name}-sg"
    }
  )
}

# 3. IAM Role & Instance Profile for AWS Systems Manager (No SSH required)
resource "aws_iam_role" "nitro_host" {
  name_prefix = "${var.instance_name}-role-"
  description = "IAM role for Nitro Sandbox host with SSM management"

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

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.nitro_host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nitro_host" {
  name_prefix = "${var.instance_name}-profile-"
  role        = aws_iam_role.nitro_host.name
}

# 4. Nitro Sandbox Host EC2 Instance
resource "aws_instance" "nitro_host" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.nitro_host.id]
  iam_instance_profile   = aws_iam_instance_profile.nitro_host.name

  enclave_options {
    enabled = var.enable_nitro_enclaves
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 strictly enforced
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -euo pipefail

              echo "Configuring AWS Nitro Sandbox Host Environment..."
              dnf update -y
              dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel

              # Add ec2-user to nitro-enclaves group
              usermod -aG ne ec2-user

              # Configure Nitro Enclaves allocator
              systemctl enable --now nitro-enclaves-allocator.service

              # Check Nitro system capability
              nitro-cli --version || true

              echo "Nitro Sandbox Host Bootstrap Complete."
              EOF

  tags = merge(
    var.tags,
    {
      Environment                   = var.environment
      Name                          = var.instance_name
      "sandbox.aws.amazon.com/type" = "nitro-host"
    }
  )
}
