data "aws_partition" "current" {}
data "aws_region" "current" {}

# 1. ECS Cluster with Container Insights
resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}

# 2. CloudWatch Log Group for Task Logging
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/aws/ecs/${var.cluster_name}"
  retention_in_days = 30

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}

# 3. Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "${var.cluster_name}-task-sg-"
  description = "Security group for ECS Nitro Sandbox tasks"
  vpc_id      = var.vpc_id

  #trivy:ignore:AVD-AWS-0104:Required for outbound HTTPS to ECR and AWS APIs
  egress {
    description = "Allow HTTPS egress for container image pulls and AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
      Name        = "${var.cluster_name}-tasks-sg"
    }
  )
}

# 4. IAM Roles for ECS Execution and Task
resource "aws_iam_role" "execution" {
  name_prefix = "${var.cluster_name}-exec-role-"
  description = "Execution role for ECS agent to pull images and push logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name_prefix = "${var.cluster_name}-task-role-"
  description = "Task role assumed by sandboxed container workload"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# 5. Standard ECS Task Definition (Native Provider Resource)
# NOTE: In terraform-provider-aws (v6.x), the aws_ecs_task_definition resource
# does not yet expose trusted_execution_configuration directly in its schema.
# The standard definition manages the workload baseline:
resource "aws_ecs_task_definition" "standard" {
  family                   = "${var.cluster_name}-workload"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "sandbox-app"
      image     = var.container_image
      essential = true
      command   = ["/bin/sh", "-c", "echo 'ECS Task Running'; while true; do sleep 3600; done"]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "sandbox"
        }
      }
      readonlyRootFilesystem = true
      user                   = "10001"
      linuxParameters = {
        initProcessEnabled = true
        capabilities = {
          drop = ["ALL"]
        }
      }
    }
  ])

  tags = var.tags
}

# 6. Native AWS Cloud Control API Resource for Nitro Sandbox Task Definition
# This provides the official AWS API bridge for TrustedExecutionConfiguration
# without invoking local-exec or external scripts.
resource "aws_cloudcontrolapi_resource" "nitro_task_def" {
  count     = var.enable_cloudcontrol_nitro_task ? 1 : 0
  type_name = "AWS::ECS::TaskDefinition"

  desired_state = jsonencode({
    Family                  = "${var.cluster_name}-nitro-sandbox"
    RequiresCompatibilities = ["EC2"]
    NetworkMode             = "awsvpc"
    Cpu                     = var.task_cpu
    Memory                  = var.task_memory
    ExecutionRoleArn        = aws_iam_role.execution.arn
    TaskRoleArn             = aws_iam_role.task.arn
    RuntimePlatform = {
      OperatingSystemFamily = "LINUX"
      CpuArchitecture       = "X86_64"
    }
    TrustedExecutionConfiguration = {
      IsolationMode = var.isolation_mode
    }
    ContainerDefinitions = [
      {
        Name      = "nitro-sandbox-app"
        Image     = var.container_image
        Essential = true
        Command   = ["/bin/sh", "-c", "echo 'ECS Nitro Sandbox Task Running'; while true; do sleep 3600; done"]
        LogConfiguration = {
          LogDriver = "awslogs"
          Options = {
            "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
            "awslogs-region"        = data.aws_region.current.region
            "awslogs-stream-prefix" = "nitro-sandbox"
          }
        }
        ReadonlyRootFilesystem = true
        User                   = "10001"
      }
    ]
  })
}

# 7. Optional ECS Service (EC2 Launch Type with awsvpc networking)
resource "aws_ecs_service" "sample" {
  name            = "${var.cluster_name}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.standard.arn
  desired_count   = 0 # Default 0 to prevent scheduling errors until ECS container instances join
  launch_type     = "EC2"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}
