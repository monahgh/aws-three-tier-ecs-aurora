# ECS Fargate (ARM64): API service behind the ALB + pgbench load generator.
# No Docker builds: public images, code injected at startup through base64 env vars.

resource "aws_ecs_cluster" "main" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  depends_on = [aws_cloudwatch_log_group.container_insights]
}

# Container Insights log group, pre-created for retention and clean destroy.
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/ecs/containerinsights/${var.project_name}/performance"
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project_name}/api"
  retention_in_days = 3
}

resource "aws_cloudwatch_log_group" "loadgen" {
  name              = "/ecs/${var.project_name}/loadgen"
  retention_in_days = 3
}

# --- IAM ---------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by ECS itself to pull images, write logs and inject secrets.
resource "aws_iam_role" "task_execution" {
  name               = "${var.project_name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_execution_secret" {
  name = "read-db-secret"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = local.db_secret_arn
    }]
  })
}

# Task role: what the application itself may call. Only ECS Exec (debug shell) here.
resource "aws_iam_role" "task" {
  name               = "${var.project_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task_exec_command" {
  name = "ecs-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# --- API service -------------------------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project_name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "api"
    image     = var.api_image
    essential = true
    command = [
      "sh", "-c",
      "mkdir -p /app && cd /app && echo \"$APP_JS_B64\" | base64 -d > server.js && npm install --no-audit --no-fund --silent pg@8 && exec node server.js"
    ]
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment = [
      { name = "APP_JS_B64", value = base64encode(file("${path.module}/../app/api/server.js")) },
      { name = "PORT", value = "3000" },
      { name = "DB_HOST_RW", value = aws_db_proxy.main.endpoint },
      { name = "DB_HOST_RO", value = aws_db_proxy_endpoint.read_only.endpoint },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SSL_REJECT_UNAUTHORIZED", value = "false" },
    ]
    secrets = [
      { name = "DB_USER", valueFrom = "${local.db_secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${local.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "api"
      }
    }
  }])
}

resource "aws_ecs_service" "api" {
  name                              = "api"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.api.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  enable_execute_command            = true
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Autoscaling owns desired_count after the first apply.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener_rule.from_cloudfront, aws_db_proxy_endpoint.read_only]
}

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 1
  max_capacity       = 4
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${var.project_name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# --- Load generator (pgbench through RDS Proxy) ------------------------------

resource "aws_ecs_task_definition" "loadgen" {
  family                   = "${var.project_name}-loadgen"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name       = "loadgen"
    image      = var.loadgen_image
    essential  = true
    entryPoint = ["sh", "-c"]
    command    = ["echo \"$LOADGEN_SH_B64\" | base64 -d > /tmp/loadgen.sh && exec sh /tmp/loadgen.sh"]
    environment = [
      { name = "LOADGEN_SH_B64", value = base64encode(file("${path.module}/../app/loadgen/loadgen.sh")) },
      { name = "PGHOST", value = aws_db_proxy.main.endpoint },
      { name = "PGPORT", value = "5432" },
      { name = "PGDATABASE", value = var.db_name },
      { name = "PGSSLMODE", value = "require" },
      { name = "PGBENCH_SCALE", value = "10" },
      { name = "PGBENCH_CLIENTS", value = "8" },
      { name = "PGBENCH_RATE", value = tostring(var.loadgen_rate) },
      { name = "PGBENCH_EXTRA_FLAGS", value = var.loadgen_extra_flags },
    ]
    secrets = [
      { name = "PGUSER", valueFrom = "${local.db_secret_arn}:username::" },
      { name = "PGPASSWORD", valueFrom = "${local.db_secret_arn}:password::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.loadgen.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "loadgen"
      }
    }
  }])
}

resource "aws_ecs_service" "loadgen" {
  name                   = "loadgen"
  cluster                = aws_ecs_cluster.main.id
  task_definition        = aws_ecs_task_definition.loadgen.arn
  desired_count          = var.loadgen_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  depends_on = [aws_db_proxy_target.main]
}
