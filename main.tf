provider "aws" {
  region = local.region

  assume_role {
    role_arn = var.workspace_iam_roles[terraform.workspace]
  }
}

locals {
  region              = var.region
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"
  environment         = var.environment
  domain_name         = "${terraform.workspace}.${var.root_domain_name}"
  account_id          = data.aws_caller_identity.current.account_id

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  vanta_enabled = terraform.workspace == "mcro" ? 1 : 0

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {}

################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1"

  name = "${local.namespace}-vpc"
  cidr = local.vpc_cidr

  azs              = local.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # vpc flow logs (cloudwatch log group and iam role will be created)
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true

  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_name_prefix       = "/aws/${local.namespace}/"
  flow_log_cloudwatch_log_group_retention_in_days = 365
}

################################################################################
# ECS Module
################################################################################

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.2"

  cluster_name = "${local.namespace}-cluster"

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 365

  # capacity provider
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 50
        base   = 20
      }
    }
    FARGATE_SPOT = {
      default_capacity_provider_strategy = {
        weight = 50
      }
    }
  }

  tags = local.tags
}

################################################################################
# ALB Module
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.7"

  name = "${local.namespace}-alb"

  load_balancer_type = "application"

  vpc_id                = module.vpc.vpc_id
  subnets               = module.vpc.public_subnets
  security_groups       = [module.security_group_alb.security_group_id]
  create_security_group = false

  http_tcp_listeners = [
    {
      port        = 80
      protocol    = "HTTP"
      action_type = "redirect"
      redirect    = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  ]

  https_listeners = [
    {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = module.acm_certificate.acm_certificate_arn
      action_type     = "fixed-response"
      fixed_response  = {
        content_type = "text/plain"
        message_body = "Unauthorized"
        status_code  = "401"
      }
    },
  ]

  tags = local.tags
}

resource "aws_alb_listener_rule" "this" {
  listener_arn = tolist(module.alb.https_listener_arns)[0]
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = module.server.target_group_arn
  }

  condition {
    host_header {
      values = ["api.${local.domain_name}"]
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = module.alb.lb_arn
  web_acl_arn  = aws_wafv2_web_acl.web_acl_alb.arn
}

module "security_group_alb" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name            = "${local.namespace}-alb-sg"
  description     = "Allow all inbound traffic on the load balancer listener port"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = false

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "https-443-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_alb_unhealthy_hosts" {
  alarm_name          = "${local.namespace}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = var.statistic_period
  statistic           = "Minimum"
  threshold           = var.alb_unhealthy_hosts_threshold
  alarm_description   = "Unhealthy host count too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    LoadBalancer = module.alb.lb_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_alb_response_time" {
  alarm_name          = "${local.namespace}-alb-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = var.statistic_period
  statistic           = "Average"
  threshold           = var.alb_response_time_threshold
  alarm_description   = "Average API response time is too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    LoadBalancer = module.alb.lb_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_alb_target_5xx_count" {
  alarm_name          = "${local.namespace}-alb-5xx-count"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = var.statistic_period
  statistic           = "Sum"
  threshold           = var.alb_5xx_response_threshold
  alarm_description   = "Average API 5XX load balancer error code count is too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    LoadBalancer = module.alb.lb_id
  }

  tags = local.tags
}

################################################################################
# RDS Module
################################################################################

module "cluster" {
  source = "terraform-aws-modules/rds-aurora/aws"

  name              = "${local.workspace_namespace}-cluster"
  engine            = "aurora-postgresql"
  engine_mode       = "provisioned"
  engine_version    = "15.3"
  storage_encrypted = true

  port                        = var.rds_port
  database_name               = var.rds_database_name
  master_username             = var.rds_master_username
  master_password             = var.rds_master_password != "" ? var.rds_master_password : random_password.password[0].result
  manage_master_user_password = false

  vpc_id                 = module.vpc.vpc_id
  vpc_security_group_ids = [module.security_group_rds.security_group_id]
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  create_security_group  = false

  apply_immediately            = true
  skip_final_snapshot          = true
  performance_insights_enabled = true
  deletion_protection          = true
  monitoring_interval          = 60

  serverlessv2_scaling_configuration = {
    min_capacity = 1
    max_capacity = 32
  }

  instance_class = "db.serverless"
  instances      = {
    1 = {
      identifier = "${local.workspace_namespace}-instance-1"
    }
  }

  tags = merge(tomap({ VantaContainsUserData = "true" }), local.tags)
}

module "security_group_rds" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name            = "${local.namespace}-rds-sg"
  description     = "Control traffic to/from RDS instances"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = false

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = var.rds_port
      to_port     = var.rds_port
      protocol    = "tcp"
      description = "Allow inbound traffic from existing Security Groups"
      cidr_blocks = module.vpc.vpc_cidr_block
    }
  ]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_rds_cpu_usage" {
  alarm_name          = "${local.namespace}-rds-cpu-usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = var.statistic_period
  statistic           = "Average"
  threshold           = var.rds_cpu_usage_threshold
  alarm_description   = "Average database CPU utilization too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBClusterIdentifier = module.cluster.cluster_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_rds_local_storage" {
  alarm_name          = "${local.namespace}-rds-local-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeLocalStorage"
  namespace           = "AWS/RDS"
  period              = var.statistic_period
  statistic           = "Average"
  threshold           = var.rds_local_storage_threshold
  alarm_description   = "Average database local storage too low"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBClusterIdentifier = module.cluster.cluster_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_rds_freeable_memory" {
  alarm_name          = "${local.namespace}-rds-freeable-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = var.statistic_period
  statistic           = "Average"
  threshold           = var.rds_freeable_memory_threshold
  alarm_description   = "Average database random access memory too low"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBClusterIdentifier = module.cluster.cluster_id
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_rds_disk_queue_depth_high" {
  alarm_name          = "${local.namespace}-rds-disk-queue-depth-high"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DiskQueueDepth"
  namespace           = "AWS/RDS"
  period              = var.statistic_period
  statistic           = "Average"
  threshold           = var.rds_freeable_memory_threshold
  alarm_description   = "Average database disk queue depth too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBClusterIdentifier = module.cluster.cluster_id
  }

  tags = local.tags
}

################################################################################
# Security Module
################################################################################

resource "aws_securityhub_account" "securityhub_account" {
  enable_default_standards = true
}

resource "aws_guardduty_detector" "guardduty_detector" {
  enable = true
}

resource "aws_cloudwatch_event_rule" "cloudwatch_event_rule_guardduty" {
  name          = "${local.namespace}-guardduty-finding-events"
  description   = "AWS GuardDuty event findings"
  event_pattern = jsonencode(
    {
      "detail-type" : [
        "GuardDuty Finding"
      ],
      "source" : [
        "aws.guardduty"
      ]
    })
}

resource "aws_cloudwatch_event_target" "cloudwatch_event_target_alerts" {
  rule      = aws_cloudwatch_event_rule.cloudwatch_event_rule_guardduty.name
  target_id = "${local.namespace}-send-to-sns-alerts"
  arn       = aws_sns_topic.sns_topic_alerts.arn

  input_transformer {
    input_paths = {
      title       = "$.detail.title"
      description = "$.detail.description"
      eventTime   = "$.detail.service.eventFirstSeen"
      region      = "$.detail.region"
    }

    input_template = "\"GuardDuty finding in <region> first seen at <eventTime>: <title> <description>\""
  }
}

################################################################################
# Supporting Resources
################################################################################

resource "random_password" "password" {
  count   = var.rds_master_password != "" ? 0 : 1
  length  = 20
  special = false
}

resource "aws_sns_topic" "sns_topic_alerts" {
  name = "${local.namespace}-alerts"
}

resource "aws_sns_topic_subscription" "sns_topic_subscription_notifications" {
  topic_arn = aws_sns_topic.sns_topic_alerts.arn
  protocol  = "email"
  endpoint  = var.notifications_email
}

module "acm_certificate" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.3.2"

  domain_name = local.domain_name
  zone_id     = aws_route53_zone.this.zone_id

  subject_alternative_names = [
    "api.${local.domain_name}",
    "assets.${local.domain_name}",
  ]

  tags = local.tags
}

resource "aws_route53_zone" "this" {
  name          = local.domain_name
  force_destroy = false

  tags = local.tags
}

resource "aws_route53_record" "route53_wildcard_record" {
  zone_id = aws_route53_zone.this.zone_id
  name    = "api.${local.domain_name}"
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
  }
}

resource "aws_wafv2_web_acl" "web_acl_cloudfront" {
  name  = "${local.namespace}-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.namespace}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl" "web_acl_alb" {
  name  = "${local.namespace}-alb-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.namespace}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

################################################################################
# Server Module
################################################################################

module "server" {
  source = "./modules/server"

  region                          = local.region
  environment                     = local.environment
  domain_name                     = local.domain_name
  vpc_id                          = module.vpc.vpc_id
  certificate_arn                 = module.acm_certificate.acm_certificate_arn
  load_balancer_security_group_id = module.security_group_alb.security_group_id
  route53_zone_id                 = aws_route53_zone.this.zone_id
  web_acl_arn                     = aws_wafv2_web_acl.web_acl_cloudfront.arn
  ecs_cluster_name                = module.ecs.cluster_name
  rds_cluster_identifier          = module.cluster.cluster_id
  rds_master_password             = var.rds_master_password != "" ? var.rds_master_password : random_password.password[0].result

  depends_on = [
    module.ecs,
  ]
}

################################################################################
# Web Module
################################################################################

module "web" {
  source = "./modules/web"

  region          = local.region
  environment     = local.environment
  domain_name     = local.domain_name
  certificate_arn = module.acm_certificate.acm_certificate_arn
  route53_zone_id = aws_route53_zone.this.zone_id
  web_acl_arn     = aws_wafv2_web_acl.web_acl_cloudfront.arn
}

################################################################################
# Bastion Module
################################################################################

module "bastion" {
  source = "./modules/bastion"

  region               = local.region
  environment          = local.environment
  vpc_id               = module.vpc.vpc_id
  sns_topic_alerts_arn = aws_sns_topic.sns_topic_alerts.arn
}

################################################################################
# CI/CD Module
################################################################################

module "ci-cd" {
  source = "./modules/ci-cd"

  region                            = local.region
  environment                       = local.environment
  s3_bucket_name_webapp             = module.web.s3_bucket_name
  secretsmanager_secret_id_webapp   = module.web.secretsmanager_secret_id
  secretsmanager_secret_id_server   = module.server.secretsmanager_secret_id
  ecr_repository_url_webapp         = module.web.ecr_repository_url
  ecr_repository_url_server         = module.server.ecr_repository_url
  ecs_cluster_name                  = module.ecs.cluster_name
  ecs_service_name_server           = module.server.ecs_service_name
  cloudfront_distribution_id_webapp = module.web.cloudfront_distribution_id

#  depends_on = [
#    module.web,
#    module.server,
#  ]
}

################################################################################
# Vanta Module
################################################################################

module "vanta" {
  source = "./modules/vanta"

  count       = local.vanta_enabled
  region      = local.region
  environment = local.environment
}
