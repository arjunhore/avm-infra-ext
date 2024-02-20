locals {
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"
  domain_name         = var.domain_name
  certificate_arn     = var.certificate_arn
  account_id          = data.aws_caller_identity.current.account_id
  
  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_caller_identity" "current" {}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "aws_s3_bucket_web" {
  bucket        = "${local.workspace_namespace}-web-${local.account_id}"
  force_destroy = true
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

  aliases = ["admin.${local.domain_name}"]
  comment = "admin"

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

  tags = local.tags
}

################################################################################
# ECR Repository
################################################################################

module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 1.6.0"

  repository_name                   = "avm-webapp"
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

resource "aws_secretsmanager_secret" "this" {
  name = "${local.namespace}-webapp"

  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(
    {
      "REACT_APP_FIREBASE_API_KEY" : var.firebase_api_key,
      "REACT_APP_FIREBASE_AUTH_DOMAIN" : var.firebase_auth_domain,
      "REACT_APP_FIREBASE_PROJECT_ID" : var.firebase_project_id,
      "REACT_APP_FIREBASE_STORAGE_BUCKET" : var.firebase_storage_bucket,
      "REACT_APP_FIREBASE_MESSAGING_SENDER_ID" : var.firebase_messaging_sender_id,
      "REACT_APP_FIREBASE_APP_ID" : var.firebase_app_id,
      "REACT_APP_FIREBASE_MEASUREMENT_ID" : var.firebase_measurement_id,
    })

  lifecycle {
    ignore_changes = [secret_string,]
  }
}

resource "aws_route53_record" "route53_wildcard_record" {
  zone_id = var.route53_zone_id
  name    = "admin.${local.domain_name}"
  type    = "A"

  alias {
    evaluate_target_health = false
    name                   = module.cdn.cloudfront_distribution_domain_name
    zone_id                = module.cdn.cloudfront_distribution_hosted_zone_id
  }
}
