variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag" {
  type        = string
  description = "Immutable image tag (git SHA) to deploy"
}

variable "db_endpoint" {
  type = string
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager ARN holding the RDS master password"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

resource "aws_security_group" "ecs" {
  name        = "${var.name}-ecs-sg"
  description = "ECS tasks: app port only from the ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [var.alb_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-ecs-sg" }
}

# Task execution role: only what Fargate needs (pull image, write logs,
# read the DB secret). Nothing else.
resource "aws_iam_role" "execution" {
  name = "${var.name}-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "${var.name}-ecs-secret-read"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.db_secret_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}-app"
  retention_in_days = 30
  tags              = { Name = "${var.name}-app-logs" }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster"
  tags = { Name = "${var.name}-cluster" }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name}-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${var.ecr_repository_url}:${var.image_tag}"
    essential = true
    portMappings = [{ containerPort = 5000, protocol = "tcp" }]
    environment = [
      { name = "PORT", value = "5000" },
      { name = "LOG_LEVEL", value = "INFO" },
    ]
    secrets = [{
      # DATABASE_URL is assembled from the endpoint + the managed secret.
      # In practice: name = "DATABASE_URL", valueFrom = secret ARN with a
      # json key; simplified here for readability.
      name      = "DB_PASSWORD"
      valueFrom = var.db_secret_arn
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "app"
      }
    }
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:5000/healthz')\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])

  tags = { Name = "${var.name}-app-task" }
}

data "aws_region" "current" {}

resource "aws_ecs_service" "app" {
  name            = "${var.name}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = 5000
  }

  # Rolling deployment: ECS replaces tasks gradually, the ALB drains
  # connections. For zero-downtime blue/green, wire this service to
  # CodeDeploy (see pipeline/README note) — the task definition shape
  # stays the same.
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_iam_role_policy_attachment.execution_base]

  tags = { Name = "${var.name}-app-service" }
}

output "ecs_sg_id" {
  value = aws_security_group.ecs.id
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}
