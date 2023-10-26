provider "aws" {
  region = "us-east-1" # CloudFront only supports ACM in "us-east-1"
}

locals {
  namespace   = "avm-${var.environment}"
  domain_name = "${terraform.workspace}.${var.root_domain_name}"

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

module "acm_certificate" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.3.2"

  domain_name = local.domain_name
  zone_id     = var.route53_zone_id

  subject_alternative_names = [
    "assets.${local.domain_name}",
    "chat.${local.domain_name}",
    "admin.${local.domain_name}",
  ]

  tags = local.tags
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
