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
  domain_name         = "${terraform.workspace}.${var.domain_name}"
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
      certificate_arn = module.acm_wildcard_cert.acm_certificate_arn
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

  port            = var.rds_port
  database_name   = var.rds_database_name
  master_username = var.rds_master_username
  master_password = var.rds_master_password != "" ? var.rds_master_password : random_password.password[0].result

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

  tags = local.tags
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

resource "aws_cloudwatch_metric_alarm" "rds_cloudwatch_alarm_cpu_usage_high" {
  alarm_name          = "${module.cluster.cluster_database_name}-rds-cpu-usage-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_cpu_usage_threshold
  alarm_description   = "Average database CPU utilization over last 5 minutes too high"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBInstanceIdentifier = module.cluster.cluster_database_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cloudwatch_alarm_memory_usage_high" {
  alarm_name          = "${module.cluster.cluster_database_name}-rds-memory-usage-high"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_freeable_memory_threshold
  alarm_description   = "Average database freeable memory over last 5 minutes too low, performance may suffer"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBInstanceIdentifier = module.cluster.cluster_database_name
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cloudwatch_alarm_disk_queue_depth_high" {
  alarm_name          = "${module.cluster.cluster_database_name}-rds-disk-queue-depth-high"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DiskQueueDepth"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.rds_disk_queue_depth_threshold
  alarm_description   = "Average database disk queue depth over last 5 minutes too high, performance may suffer"

  alarm_actions = aws_sns_topic.sns_topic_alerts.*.arn
  ok_actions    = aws_sns_topic.sns_topic_alerts.*.arn

  dimensions = {
    DBInstanceIdentifier = module.cluster.cluster_database_name
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_guardduty_detector" "guardduty_detector" {
  enable = true
}

resource "aws_sns_topic" "sns_topic_alerts" {
  name = "${local.namespace}-alerts"
}

resource "aws_sns_topic_subscription" "sns_topic_subscription_notifications" {
  topic_arn = aws_sns_topic.sns_topic_alerts.arn
  protocol  = "email"
  endpoint  = var.notifications_email
}

resource "random_password" "password" {
  count   = var.rds_master_password != "" ? 0 : 1
  length  = 20
  special = false
}

module "acm_wildcard_cert" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.3.2"

  domain_name = "*.${local.domain_name}"
  zone_id     = aws_route53_zone.this.zone_id

  subject_alternative_names = [
    local.domain_name,
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
  name    = "*.${local.domain_name}"
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
  }
}

resource "aws_wafv2_web_acl" "web_acl" {
  name  = "${local.namespace}-cloudfront-waf"
  scope = "CLOUDFRONT"

  default_action {
    block {}
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
    metric_name                = "ExternalACL"
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
  certificate_arn                 = module.acm_wildcard_cert.acm_certificate_arn
  ecr_repository_image            = var.ecr_repository_image
  vpc_id                          = module.vpc.vpc_id
  ecs_cluster_id                  = module.ecs.cluster_id
  ecs_cluster_name                = module.ecs.cluster_name
  load_balancer_security_group_id = module.security_group_alb.security_group_id
  rds_security_group_id           = module.security_group_rds.security_group_id
  rds_port                        = var.rds_port
  route53_zone_id                 = aws_route53_zone.this.zone_id
  web_acl_arn                     = aws_wafv2_web_acl.web_acl.arn
}

################################################################################
# Web Module
################################################################################

module "web" {
  source = "./modules/web"

  region          = local.region
  environment     = local.environment
  domain_name     = local.domain_name
  certificate_arn = module.acm_wildcard_cert.acm_certificate_arn
  route53_zone_id = aws_route53_zone.this.zone_id
  web_acl_arn     = aws_wafv2_web_acl.web_acl.arn
}

################################################################################
# Bastion Module
################################################################################

module "bastion" {
  source = "./modules/bastion"

  region      = local.region
  environment = local.environment
  vpc_id      = module.vpc.vpc_id
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
