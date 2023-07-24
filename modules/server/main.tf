locals {
  environment = var.environment
  namespace   = "${var.namespace}-server"

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_subnets" "all" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

################################################################################
# ECS Resources
################################################################################

resource "aws_ecs_task_definition" "this" {
  family                   = local.namespace
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode(
    [
      {
        name : local.namespace,
        image : var.ecr_repository_image,
        cpu : 1024,
        memory : 2048,
        logConfiguration : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-region" : var.region,
            "awslogs-group" : aws_cloudwatch_log_group.this.name,
            "awslogs-stream-prefix" : "ec2"
          }
        },
        portMappings : [
          {
            protocol : "tcp",
            containerPort : var.docker_container_port,
            hostPort : var.docker_container_port
          }
        ]
        environment = [
          {
            "name" : "AWS_REGION",
            "value" : var.region
          },
          {
            "name" : "SECRETS_MANAGER_SECRET_ID",
            "value" : aws_secretsmanager_secret.this.name
          },
        ]
      }
    ])
}

resource "aws_ecs_service" "this" {
  name                               = local.namespace
  cluster                            = var.ecs_cluster_id
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = 1
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 0
  launch_type                        = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_service_security_group.id]
    subnets          = toset(data.aws_subnets.all.ids)
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.this.arn
    container_name   = local.namespace
    container_port   = var.docker_container_port
  }
}

resource "aws_alb_target_group" "this" {
  name                 = "${local.namespace}-tg"
  port                 = var.docker_container_port
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = "30"

  stickiness {
    type = "lb_cookie"
  }

  health_check {
    path              = "/health"
    interval          = 30
    healthy_threshold = 2
    matcher           = "200"
  }
}

resource "aws_security_group" "ecs_service_security_group" {
  name        = "${local.namespace}-ecs-sg"
  description = "Allow all inbound traffic on the container listener port"
  vpc_id      = var.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = var.docker_container_port
    to_port         = var.docker_container_port
    security_groups = [var.load_balancer_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

################################################################################
# Autoscaling
################################################################################

resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min_instances
  max_capacity       = var.autoscaling_max_instances
}

resource "aws_appautoscaling_policy" "autoscaling_up_policy" {
  name               = "${local.namespace}-scale-up-policy"
  depends_on         = [aws_appautoscaling_target.this]
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource "aws_appautoscaling_policy" "autoscaling_down_policy" {
  name               = "${local.namespace}-scale-down-policy"
  depends_on         = [aws_appautoscaling_target.this]
  service_namespace  = aws_appautoscaling_target.this.service_namespace
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_high" {
  alarm_name          = "${local.namespace}-cpu-usage-high-${var.autoscaling_cpu_high_threshold}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_cpu_high_threshold

  dimensions = {
    ClusterName = var.ecs_cluster_id
    ServiceName = aws_ecs_service.this.name
  }
  alarm_actions = [aws_appautoscaling_policy.autoscaling_up_policy.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cpu_utilization_low" {
  alarm_name          = "${local.namespace}-cpu-usage-low-${var.autoscaling_cpu_low_threshold}"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_cpu_low_threshold

  dimensions = {
    ClusterName = var.ecs_cluster_id
    ServiceName = aws_ecs_service.this.name
  }
  alarm_actions = [aws_appautoscaling_policy.autoscaling_down_policy.arn]

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_secretsmanager_secret" "this" {
  name = local.namespace
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.namespace
  retention_in_days = 90
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.namespace}-ecsTaskExecutionRole"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Action" : "sts:AssumeRole",
          "Principal" : {
            "Service" : "ecs-tasks.amazonaws.com"
          },
          "Effect" : "Allow"
        }
      ]
    })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${local.namespace}-ecsTaskRole"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Action" : "sts:AssumeRole",
          "Principal" : {
            "Service" : "ecs-tasks.amazonaws.com"
          },
          "Effect" : "Allow"
        }
      ]
    })
}

resource "aws_iam_policy" "aws_iam_policy_secrets_manager" {
  name        = "${local.namespace}-secrets-manager-policy"
  description = "Access control for Secrets Manager"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Effect" : "Allow",
          "Resource" : [
            aws_secretsmanager_secret.this.arn
          ],
        }
      ]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "secrets_manager_ecs_task_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_secrets_manager.arn
}

resource "aws_iam_role_policy_attachment" "secrets_manager_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_secrets_manager.arn
}
