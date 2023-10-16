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

data "aws_caller_identity" "current" {}

data "aws_subnets" "subnets" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_rds_cluster" "this" {
  cluster_identifier = var.rds_cluster_identifier
}

data "aws_ecs_cluster" "this" {
  cluster_name = var.ecs_cluster_name
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
            containerPort : 443,
            hostPort : 443,
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
  name                               = local.server_namespace
  cluster                            = data.aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = 1
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  launch_type                        = "FARGATE"

  network_configuration {
    security_groups  = [module.security_group_ecs_service.security_group_id]
    subnets          = toset(data.aws_subnets.subnets.ids)
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.this.arn
    container_name   = local.server_namespace
    container_port   = 443
  }

  lifecycle {
    ignore_changes = [task_definition,]
  }
}

resource "aws_alb_target_group" "this" {
  name                 = "${local.server_namespace}-tg"
  port                 = 443
  protocol             = "HTTPS"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  deregistration_delay = "30"

  stickiness {
    type = "lb_cookie"
  }

  health_check {
    protocol          = "HTTPS"
    path              = "/health"
    interval          = 30
    healthy_threshold = 2
    matcher           = "200"
  }
}

module "security_group_ecs_service" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name            = "${local.namespace}-server-sg"
  description     = "Allow all inbound traffic on the container listener port"
  vpc_id          = var.vpc_id
  use_name_prefix = false

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["https-443-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
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

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_cpu_usage_high" {
  alarm_name          = "${local.server_namespace}-cpu-usage-high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_cpu_high_threshold

  alarm_actions = [aws_appautoscaling_policy.autoscaling_up_policy.arn]

  dimensions = {
    ClusterName = data.aws_ecs_cluster.this.cluster_name
    ServiceName = aws_ecs_service.this.name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_cpu_usage_low" {
  alarm_name          = "${local.server_namespace}-cpu-usage-low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.autoscaling_cpu_low_threshold

  alarm_actions = [aws_appautoscaling_policy.autoscaling_down_policy.arn]

  dimensions = {
    ClusterName = data.aws_ecs_cluster.this.cluster_name
    ServiceName = aws_ecs_service.this.name
  }

  tags = local.tags
}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "aws_s3_bucket_documents" {
  bucket        = "${local.workspace_namespace}-documents"
  force_destroy = true
}

resource "aws_s3_bucket" "aws_s3_bucket_assets" {
  bucket        = "${local.workspace_namespace}-assets"
  force_destroy = true
}

resource "aws_s3_bucket" "aws_s3_bucket_logs" {
  bucket        = "${local.workspace_namespace}-bucket-access-logs"
  force_destroy = true
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

resource "aws_s3_bucket_cors_configuration" "aws_s3_bucket_assets_cors" {
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

resource "aws_s3_bucket_cors_configuration" "aws_s3_bucket_documents_cors" {
  bucket = aws_s3_bucket.aws_s3_bucket_documents.id

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

resource "aws_s3_bucket_logging" "aws_s3_bucket_logging_documents" {
  bucket = aws_s3_bucket.aws_s3_bucket_documents.id

  target_bucket = aws_s3_bucket.aws_s3_bucket_logs.id
  target_prefix = aws_s3_bucket.aws_s3_bucket_documents.bucket
}

resource "aws_s3_bucket_logging" "aws_s3_bucket_logging_assets" {
  bucket = aws_s3_bucket.aws_s3_bucket_assets.id

  target_bucket = aws_s3_bucket.aws_s3_bucket_logs.id
  target_prefix = aws_s3_bucket.aws_s3_bucket_assets.bucket
}

################################################################################
# CloudFront
################################################################################

module "cdn" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 3.2.1"

  aliases = ["assets.${local.domain_name}"]
  comment = "assets"

  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"
  web_acl_id      = var.web_acl_arn

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

  tags = local.tags
}

################################################################################
# ECR Repository
################################################################################

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6.0"

  repository_name                   = "avm-server"
  repository_read_write_access_arns = [data.aws_caller_identity.current.arn]
  create_lifecycle_policy           = true

  repository_image_tag_mutability = "MUTABLE"
  repository_encryption_type      = "KMS"
  repository_force_delete         = true

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep only tagged images",
        selection    = {
          tagStatus   = "untagged",
          countType   = "imageCountMoreThan",
          countNumber = 1
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

resource "random_password" "password" {
  count   = 1
  length  = 30
  special = true
}

resource "aws_secretsmanager_secret" "this" {
  name = local.server_namespace

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(
    {
      "NODE_ENV" : "production",
      "AWS_REGION" : var.region,
      "AWS_DOCUMENTS_S3_BUCKET" : aws_s3_bucket.aws_s3_bucket_documents.bucket,
      "AWS_ASSETS_S3_BUCKET" : aws_s3_bucket.aws_s3_bucket_assets.bucket,
      "AWS_DEFAULT_KMS_KEY_ID" : aws_kms_key.kms_key_server.key_id,
      "DB_URI" : "postgres://${data.aws_rds_cluster.this.master_username}:${var.rds_master_password}@${data.aws_rds_cluster.this.endpoint}:${data.aws_rds_cluster.this.port}/${data.aws_rds_cluster.this.database_name}",
      "DB_VECTOR_URI" : "postgres://${data.aws_rds_cluster.this.master_username}:${var.rds_master_password}@${data.aws_rds_cluster.this.endpoint}:${data.aws_rds_cluster.this.port}/vectordb",
      "UI_HOST" : "https://${local.domain_name}"
      "API_KEY" : random_password.password[0].result,
      "FIREBASE_PRIVATE_KEY" : "<REPLACE_ME>",
      "FIREBASE_CLIENT_EMAIL" : "<REPLACE_ME>",
      "FIREBASE_PROJECT_ID" : "<REPLACE_ME>",
      "GOOGLE_DRIVE_CLIENT_ID" : "<REPLACE_ME>",
      "GOOGLE_DRIVE_CLIENT_SECRET" : "<REPLACE_ME>",
      "AWS_SES_ACCESS_KEY" : "<REPLACE_ME>",
      "AWS_SES_SECRET_KEY" : "<REPLACE_ME>",
    })

  lifecycle {
    ignore_changes = [secret_string,]
  }
}

resource "aws_kms_key" "kms_key_server" {
  description = "KMS for server side encryption"

  tags = local.tags
}

resource "aws_kms_alias" "kms_alias_server" {
  name          = "alias/${local.server_namespace}-kms-key"
  target_key_id = aws_kms_key.kms_key_server.key_id
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.server_namespace
  retention_in_days = 365
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

resource "aws_iam_policy" "aws_iam_policy_bedrock" {
  name        = "${local.namespace}-bedrock-policy"
  description = "Access control for Bedrock resources"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "bedrock:*"
          ],
          "Resource" : [
            "*",
          ]
        },
      ]
    })
}

resource "aws_iam_policy" "aws_iam_policy_sagemaker" {
  name        = "${local.namespace}-sagemaker-policy"
  description = "Access control for Sagemaker resources"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "sagemaker:*"
          ],
          "Resource" : [
            "*",
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

resource "aws_iam_role_policy_attachment" "comprehend_medical_ecs_task_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/ComprehendMedicalFullAccess"
}

resource "aws_iam_role_policy_attachment" "comprehend_medical_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/ComprehendMedicalFullAccess"
}

resource "aws_iam_role_policy_attachment" "s3_ecs_task_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_s3.arn
}

resource "aws_iam_role_policy_attachment" "s3_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_s3.arn
}

resource "aws_iam_role_policy_attachment" "bedrock_ecs_task_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_bedrock.arn
}

resource "aws_iam_role_policy_attachment" "bedrock_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_bedrock.arn
}

resource "aws_iam_role_policy_attachment" "sagemaker_ecs_task_role_policy_attachment" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_sagemaker.arn
}

resource "aws_iam_role_policy_attachment" "sagemaker_ecs_task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.aws_iam_policy_sagemaker.arn
}

resource "aws_route53_record" "this" {
  zone_id = var.route53_zone_id
  name    = "assets.${local.domain_name}"
  type    = "CNAME"
  ttl     = 300

  records = [module.cdn.cloudfront_distribution_domain_name]
}
