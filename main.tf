provider "aws" {
  region = local.region

  assume_role {
    role_arn = var.workspace_iam_roles[terraform.workspace]
  }
}

locals {
  region      = var.region
  namespace   = "avm-${terraform.workspace}-${var.environment}"
  environment = var.environment
  domain_name = "${terraform.workspace}.${var.domain_name}"
  account_id  = data.aws_caller_identity.current.account_id

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

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

  flow_log_max_aggregation_interval         = 60
  flow_log_cloudwatch_log_group_name_prefix = "/aws/${local.namespace}/"

  tags = local.tags
}

################################################################################
# ECS Module
################################################################################

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.2"

  cluster_name = "${local.namespace}-cluster"

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

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.security_group.security_group_id]

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

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name        = "${local.namespace}-alb-security-group"
  description = "Allow all inbound traffic on the load balancer listener port"
  vpc_id      = module.vpc.vpc_id

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

  name              = "${local.namespace}-cluster"
  engine            = "aurora-postgresql"
  engine_mode       = "provisioned"
  engine_version    = "15.3"
  storage_encrypted = true

  master_username = "avm"
  master_password = var.rds_master_password != "" ? var.rds_master_password : random_password.password[0].result

  vpc_id                 = module.vpc.vpc_id
  subnets                = module.vpc.database_subnets
  create_db_subnet_group = true
  create_security_group  = true
  monitoring_interval    = 60

  apply_immediately   = true
  skip_final_snapshot = true

  serverlessv2_scaling_configuration = {
    min_capacity = 0.5
    max_capacity = 32
  }

  instance_class = "db.serverless"
  instances      = {
    1 = {
      identifier = "${local.namespace}-instance-1"
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

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

resource "aws_route53_record" "route53_root_record" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
  }
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

################################################################################
# Server Module
################################################################################

module "server" {
  source = "./modules/server"

  region                          = local.region
  environment                     = local.environment
  namespace                       = local.namespace
  domain_name                     = local.domain_name
  certificate_arn                 = module.acm_wildcard_cert.acm_certificate_arn
  ecr_repository_image            = var.ecr_repository_image
  vpc_id                          = module.vpc.vpc_id
  ecs_cluster_id                  = module.ecs.cluster_id
  ecs_cluster_name                = module.ecs.cluster_name
  load_balancer_security_group_id = module.security_group.security_group_id
}

################################################################################
# Web Module
################################################################################

module "web" {
  source = "./modules/web"

  region          = local.region
  environment     = local.environment
  namespace       = local.namespace
  domain_name     = local.domain_name
  certificate_arn = module.acm_wildcard_cert.acm_certificate_arn
}