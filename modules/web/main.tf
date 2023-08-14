locals {
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"
  domain_name         = var.domain_name
  certificate_arn     = var.certificate_arn

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "aws_s3_bucket_web" {
  bucket = "${local.workspace_namespace}-web"
}

resource "aws_s3_bucket_policy" "aws_s3_bucket_policy_cloudfront_oai" {
  bucket = aws_s3_bucket.aws_s3_bucket_web.id
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
          "Resource" : "${aws_s3_bucket.aws_s3_bucket_web.arn}/*",
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

resource "aws_s3_bucket_cors_configuration" "aws_s3_bucket_web_cors" {
  bucket = aws_s3_bucket.aws_s3_bucket_web.id

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

  aliases = [local.domain_name]

  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  default_root_object = "index.html"
  web_acl_id          = var.web_acl_arn

  create_origin_access_control = true
  origin_access_control        = {
    web_s3_oac = {
      description      = "CloudFront access for S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  origin = {
    web_s3 = {
      domain_name           = aws_s3_bucket.aws_s3_bucket_web.bucket_regional_domain_name
      origin_access_control = "web_s3_oac" # key in `origin_access_control`
    }
  }

  default_cache_behavior = {
    target_origin_id       = "web_s3"
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
    redirect_http_to_https   = true
  }

  custom_error_response = [
    {
      error_caching_min_ttl = 0
      error_code            = 403
      response_code         = 200
      response_page_path    = "/index.html"
    },
    {
      error_caching_min_ttl = 0
      error_code            = 404
      response_code         = 200
      response_page_path    = "/index.html"
    },
  ]
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_secretsmanager_secret" "this" {
  name = "${local.namespace}-webapp"
}

resource "aws_route53_record" "route53_wildcard_record" {
  zone_id = var.route53_zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = module.cdn.cloudfront_distribution_domain_name
    zone_id                = module.cdn.cloudfront_distribution_hosted_zone_id
  }
}
