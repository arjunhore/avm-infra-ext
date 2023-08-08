locals {
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"
  server_namespace    = "${local.namespace}-server"
  domain_name         = var.domain_name
  certificate_arn     = var.certificate_arn

  tags = {
    Name        = local.server_namespace
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
  family                   = local.server_namespace
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode(
    [
      {
        name : local.server_namespace,
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
        environmentFiles : [
          {
            "value" : "${aws_s3_bucket.aws_s3_bucket_envs.arn}/server.env",
            "type" : "s3"
          }
        ],
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
  name                               = local.server_namespace
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
    container_name   = local.server_namespace
    container_port   = var.docker_container_port
  }
}

resource "aws_alb_target_group" "this" {
  name                 = "${local.server_namespace}-tg"
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
  name        = "${local.server_namespace}-ecs-sg"
  description = "Allow all inbound traffic on the container listener port"
  vpc_id      = var.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = var.docker_container_port
    to_port         = var.docker_container_port
    security_groups = [var.load_balancer_security_group_id]
  }

  ingress {
    protocol        = "tcp"
    from_port       = var.rds_port
    to_port         = var.rds_port
    security_groups = [var.rds_security_group_id]
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
  name               = "${local.server_namespace}-scale-up-policy"
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
  name               = "${local.server_namespace}-scale-down-policy"
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
  alarm_name          = "${local.server_namespace}-cpu-usage-high-${var.autoscaling_cpu_high_threshold}"
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
  alarm_name          = "${local.server_namespace}-cpu-usage-low-${var.autoscaling_cpu_low_threshold}"
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
# S3
################################################################################

resource "aws_s3_bucket" "aws_s3_bucket_envs" {
  bucket = "${local.workspace_namespace}-envs"
}

resource "aws_s3_bucket" "aws_s3_bucket_documents" {
  bucket = "${local.workspace_namespace}-documents"
}

resource "aws_s3_bucket" "aws_s3_bucket_assets" {
  bucket = "${local.workspace_namespace}-assets"
}

resource "aws_s3_bucket_policy" "aws_s3_bucket_policy_cloudfront_oai" {
  bucket = aws_s3_bucket.aws_s3_bucket_assets.id
  policy = jsonencode(
    {
      "Version" : "2008-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "cloudfront.amazonaws.com"
          },
          "Action" : "s3:GetObject",
          "Resource" : "${aws_s3_bucket.aws_s3_bucket_assets.arn}/*",
          "Condition" : {
            "StringEquals" : {
              "AWS:SourceArn" : module.cdn.cloudfront_distribution_arn
            }
          }
        }
      ]
    }
  )
}

resource "aws_s3_bucket_cors_configuration" "aws_s3_bucket_docs_cors" {
  bucket = aws_s3_bucket.aws_s3_bucket_assets.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = []
    max_age_seconds = 3000
  }

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = ["*"]
  }
}

################################################################################
# CloudFront
################################################################################

module "cdn" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 3.2.1"

  aliases = ["assets.${local.domain_name}"]

  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  create_origin_access_control = true
  origin_access_control        = {
    assets_s3_oac = {
      description      = "CloudFront access for S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  origin = {
    assets_s3 = {
      domain_name           = aws_s3_bucket.aws_s3_bucket_assets.bucket_regional_domain_name
      origin_access_control = "assets_s3_oac" # key in `origin_access_control`
    }
  }

  default_cache_behavior = {
    target_origin_id       = "assets_s3"
    viewer_protocol_policy = "allow-all"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
    query_string    = false
  }

  viewer_certificate = {
    acm_certificate_arn      = local.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_secretsmanager_secret" "this" {
  name = local.server_namespace
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.server_namespace
  retention_in_days = 90
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.server_namespace}-ecsTaskExecutionRole"

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
  name = "${local.server_namespace}-ecsTaskRole"

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
  name        = "${local.server_namespace}-secrets-manager-policy"
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

resource "aws_iam_policy" "aws_iam_policy_s3" {
  name        = "${local.namespace}-s3-policy"
  description = "Access control for S3 resources"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:*"
          ],
          "Resource" : [
            "arn:aws:s3:::${local.workspace_namespace}-*",
            "arn:aws:s3:::${local.workspace_namespace}-*/*",
          ]
        },
      ]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
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

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "comprehend_ecs_task_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/ComprehendFullAccess"
}

resource "aws_iam_role_policy_attachment" "comprehend_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/ComprehendFullAccess"
}

resource "aws_iam_role_policy_attachment" "ses_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSESFullAccess"
}

resource "aws_iam_role_policy_attachment" "s3_ecs_task_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_s3.arn
}

resource "aws_iam_role_policy_attachment" "s3_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_s3.arn
}

resource "aws_route53_record" "this" {
  zone_id = var.route53_zone_id
  name    = "assets.${local.domain_name}"
  type    = "CNAME"
  ttl     = 300

  records = [module.cdn.cloudfront_distribution_domain_name]
}
