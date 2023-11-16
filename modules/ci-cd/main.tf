locals {
  region              = var.region
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"

  ecr_repository_name_webapp = split("/", var.ecr_repository_url_webapp)[1]
  ecr_repository_name_chat   = split("/", var.ecr_repository_url_chat)[1]
  ecr_repository_name_server = split("/", var.ecr_repository_url_server)[1]

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_caller_identity" "current" {}

data "aws_ecr_repository" "ecr_repository_webapp" {
  name = local.ecr_repository_name_webapp
}

data "aws_ecr_repository" "ecr_repository_chat" {
  name = local.ecr_repository_name_chat
}

data "aws_ecr_repository" "ecr_repository_server" {
  name = local.ecr_repository_name_server
}

data "aws_secretsmanager_secret" "secretsmanager_secret_webapp" {
  name = var.secretsmanager_secret_id_webapp
}

data "aws_secretsmanager_secret" "secretsmanager_secret_chat" {
  name = var.secretsmanager_secret_id_chat
}

data "aws_secretsmanager_secret" "secretsmanager_secret_server" {
  name = var.secretsmanager_secret_id_server
}

data "aws_secretsmanager_secret" "secretsmanager_secret_registry" {
  name = var.secretsmanager_secret_id_registry
}

data "aws_s3_bucket" "s3_bucket_webapp" {
  bucket = var.s3_bucket_name_webapp
}

data "aws_s3_bucket" "s3_bucket_chat" {
  bucket = var.s3_bucket_name_chat
}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "s3_bucket_codepipeline" {
  bucket        = "${local.workspace_namespace}-codepipeline"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "s3_bucket_versioning_codepipeline" {
  bucket = aws_s3_bucket.s3_bucket_codepipeline.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "empty" {
  bucket = aws_s3_bucket.s3_bucket_codepipeline.bucket
  key    = "empty.zip"
  source = "${path.module}/files/empty.zip"
  etag   = filemd5("${path.module}/files/empty.zip")
}

################################################################################
# Lambda Resources
################################################################################

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 6.0"

  function_name = "${local.namespace}-invalidate-cloudfront"
  description   = "Invalidate CloudFront"
  handler       = "invalidate-cloudfront.lambda_handler"
  runtime       = "python3.8"

  source_path = "${path.module}/files/invalidate-cloudfront.py"

  attach_policy_json = true
  policy_json        = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "codepipeline:PutJobFailureResult",
            "codepipeline:PutJobSuccessResult",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "cloudfront:CreateInvalidation"
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ],
          "Resource" : ["*"]
        }
      ]
    })

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_invalidate_lambda_error_rate" {
  alarm_name          = "${local.namespace}-invalidate-lambda-error-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = var.statistic_period
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Lambda error rate is greater than 0"

  alarm_actions = [var.sns_topic_alerts_arn]
  ok_actions    = [var.sns_topic_alerts_arn]

  dimensions = {
    FunctionName = module.lambda_function.lambda_function_name
  }

  tags = local.tags
}

################################################################################
# CodePipeline WebApp Resources
################################################################################

resource "aws_codebuild_project" "codebuild_project_webapp" {
  name         = "${local.namespace}-webapp-codebuild"
  service_role = aws_iam_role.iam_role_codepipeline_webapp.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/files/buildspec-webapp.yml")
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
  }

  logs_config {
    cloudwatch_logs {
      group_name = "${local.namespace}-webapp-codebuild"
    }
  }

  tags = local.tags
}

resource "aws_codepipeline" "aws_codepipeline_webapp" {
  name     = "${local.namespace}-webapp-codepipeline"
  role_arn = aws_iam_role.iam_role_codepipeline_webapp.arn

  artifact_store {
    location = aws_s3_bucket.s3_bucket_codepipeline.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      input_artifacts  = []
      output_artifacts = ["source"]
      version          = "1"

      configuration = {
        "S3Bucket" : aws_s3_bucket.s3_bucket_codepipeline.bucket,
        "S3ObjectKey" : aws_s3_object.empty.key,
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project_webapp.name
        EnvironmentVariables : jsonencode([
          {
            name : "AWS_REGION",
            value : var.region,
            type : "PLAINTEXT"
          },
          {
            name : "SECRETS_MANAGER_SECRET_ID",
            value : var.secretsmanager_secret_id_webapp,
            type : "PLAINTEXT"
          },
          {
            name : "CONTAINER_REGISTRY_USERNAME",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_USERNAME"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_TOKEN",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_TOKEN"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_REPOSITORY",
            value : var.container_registry_repository_webapp,
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REGISTRY",
            value : "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REPOSITORY",
            value : data.aws_ecr_repository.ecr_repository_webapp.repository_url,
            type : "PLAINTEXT"
          },
        ])
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "Deploy"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "S3"
      input_artifacts  = ["build"]
      output_artifacts = []
      version          = "1"

      configuration = {
        BucketName = data.aws_s3_bucket.s3_bucket_webapp.bucket
        Extract    = "true"
      }
    }
  }

  stage {
    name = "Cache"

    action {
      name             = "Cloudfront"
      category         = "Invoke"
      owner            = "AWS"
      provider         = "Lambda"
      input_artifacts  = []
      output_artifacts = []
      version          = "1"

      configuration = {
        FunctionName   = module.lambda_function.lambda_function_name
        UserParameters = var.cloudfront_distribution_id_webapp
      }
    }
  }

  tags = local.tags
}

resource "aws_iam_role" "iam_role_codepipeline_webapp" {
  name = "${local.namespace}-webapp-codepipeline-role"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codebuild.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        },
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codepipeline.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        }
      ]
    })

  tags = local.tags
}

resource "aws_iam_policy" "iam_policy_policy_codepipeline_webapp" {
  name        = "${local.namespace}-webapp-codepipeline-policy"
  description = "Policy for CodePipeline"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:GetBucketVersioning",
            "s3:PutObjectAcl",
            "s3:PutObject",
          ],
          "Resource" : [
            aws_s3_bucket.s3_bucket_codepipeline.arn,
            "${aws_s3_bucket.s3_bucket_codepipeline.arn}/*",
            data.aws_s3_bucket.s3_bucket_webapp.arn,
            "${data.aws_s3_bucket.s3_bucket_webapp.arn}/*",
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:DescribeImages",
            "ecr:CompleteLayerUpload",
            "ecr:GetAuthorizationToken",
            "ecr:UploadLayerPart",
            "ecr:InitiateLayerUpload",
            "ecr:BatchCheckLayerAvailability",
            "ecr:PutImage"
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Resource" : [
            data.aws_secretsmanager_secret.secretsmanager_secret_webapp.arn,
            data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn,
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "lambda:InvokeFunction",
            "lambda:ListFunctions",
          ],
          "Resource" : [
            module.lambda_function.lambda_function_arn
          ],
        }
      ]
    })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_codepipeline_webapp" {
  role       = aws_iam_role.iam_role_codepipeline_webapp.name
  policy_arn = aws_iam_policy.iam_policy_policy_codepipeline_webapp.arn
}

################################################################################
# CodePipeline Chat Resources
################################################################################

resource "aws_codebuild_project" "codebuild_project_chat" {
  name         = "${local.namespace}-chat-codebuild"
  service_role = aws_iam_role.iam_role_codepipeline_chat.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/files/buildspec-webapp.yml")
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
  }

  logs_config {
    cloudwatch_logs {
      group_name = "${local.namespace}-chat-codebuild"
    }
  }

  tags = local.tags
}

resource "aws_codepipeline" "aws_codepipeline_chat" {
  name     = "${local.namespace}-chat-codepipeline"
  role_arn = aws_iam_role.iam_role_codepipeline_chat.arn

  artifact_store {
    location = aws_s3_bucket.s3_bucket_codepipeline.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      input_artifacts  = []
      output_artifacts = ["source"]
      version          = "1"

      configuration = {
        "S3Bucket" : aws_s3_bucket.s3_bucket_codepipeline.bucket,
        "S3ObjectKey" : aws_s3_object.empty.key,
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project_chat.name
        EnvironmentVariables : jsonencode([
          {
            name : "AWS_REGION",
            value : var.region,
            type : "PLAINTEXT"
          },
          {
            name : "SECRETS_MANAGER_SECRET_ID",
            value : var.secretsmanager_secret_id_chat,
            type : "PLAINTEXT"
          },
          {
            name : "CONTAINER_REGISTRY_USERNAME",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_USERNAME"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_TOKEN",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_TOKEN"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_REPOSITORY",
            value : var.container_registry_repository_chat,
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REGISTRY",
            value : "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REPOSITORY",
            value : data.aws_ecr_repository.ecr_repository_chat.repository_url,
            type : "PLAINTEXT"
          },
        ])
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "Deploy"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "S3"
      input_artifacts  = ["build"]
      output_artifacts = []
      version          = "1"

      configuration = {
        BucketName = data.aws_s3_bucket.s3_bucket_chat.bucket
        Extract    = "true"
      }
    }
  }

  stage {
    name = "Cache"

    action {
      name             = "Cloudfront"
      category         = "Invoke"
      owner            = "AWS"
      provider         = "Lambda"
      input_artifacts  = []
      output_artifacts = []
      version          = "1"

      configuration = {
        FunctionName   = module.lambda_function.lambda_function_name
        UserParameters = var.cloudfront_distribution_id_chat
      }
    }
  }

  tags = local.tags
}

resource "aws_iam_role" "iam_role_codepipeline_chat" {
  name = "${local.namespace}-chat-codepipeline-role"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codebuild.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        },
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codepipeline.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        }
      ]
    })

  tags = local.tags
}

resource "aws_iam_policy" "iam_policy_policy_codepipeline_chat" {
  name        = "${local.namespace}-chat-codepipeline-policy"
  description = "Policy for CodePipeline"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:GetBucketVersioning",
            "s3:PutObjectAcl",
            "s3:PutObject",
          ],
          "Resource" : [
            aws_s3_bucket.s3_bucket_codepipeline.arn,
            "${aws_s3_bucket.s3_bucket_codepipeline.arn}/*",
            data.aws_s3_bucket.s3_bucket_chat.arn,
            "${data.aws_s3_bucket.s3_bucket_chat.arn}/*",
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:DescribeImages",
            "ecr:CompleteLayerUpload",
            "ecr:GetAuthorizationToken",
            "ecr:UploadLayerPart",
            "ecr:InitiateLayerUpload",
            "ecr:BatchCheckLayerAvailability",
            "ecr:PutImage"
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Resource" : [
            data.aws_secretsmanager_secret.secretsmanager_secret_chat.arn,
            data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn,
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "lambda:InvokeFunction",
            "lambda:ListFunctions",
          ],
          "Resource" : [
            module.lambda_function.lambda_function_arn
          ],
        }
      ]
    })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_codepipeline_chat" {
  role       = aws_iam_role.iam_role_codepipeline_chat.name
  policy_arn = aws_iam_policy.iam_policy_policy_codepipeline_chat.arn
}

################################################################################
# CodePipeline Server Resources
################################################################################

resource "aws_codebuild_project" "codebuild_project_server" {
  name         = "${local.namespace}-server-codebuild"
  service_role = aws_iam_role.iam_role_codepipeline_server.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/files/buildspec-server.yml")
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_MEDIUM"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true
  }

  logs_config {
    cloudwatch_logs {
      group_name = "${local.namespace}-server-codebuild"
    }
  }

  tags = local.tags
}

resource "aws_codepipeline" "aws_codepipeline_server" {
  name     = "${local.namespace}-server-codepipeline"
  role_arn = aws_iam_role.iam_role_codepipeline_server.arn

  artifact_store {
    location = aws_s3_bucket.s3_bucket_codepipeline.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "S3"
      input_artifacts  = []
      output_artifacts = ["source"]
      version          = "1"

      configuration = {
        "S3Bucket" : aws_s3_bucket.s3_bucket_codepipeline.bucket,
        "S3ObjectKey" : aws_s3_object.empty.key,
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project_server.name
        EnvironmentVariables : jsonencode([
          {
            name : "AWS_REGION",
            value : var.region,
            type : "PLAINTEXT"
          },
          {
            name : "ECS_CONTAINER_NAME",
            value : "${local.namespace}-server",
            type : "PLAINTEXT"
          },
          {
            name : "CONTAINER_REGISTRY_USERNAME",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_USERNAME"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_TOKEN",
            value : "${data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn}:${"CONTAINER_REGISTRY_TOKEN"}::"
            type : "SECRETS_MANAGER"
          },
          {
            name : "CONTAINER_REGISTRY_REPOSITORY",
            value : var.container_registry_repository_server,
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REGISTRY",
            value : "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
            type : "PLAINTEXT"
          },
          {
            name : "ECR_REPOSITORY",
            value : data.aws_ecr_repository.ecr_repository_server.repository_url,
            type : "PLAINTEXT"
          },
        ])
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name             = "Deploy"
      category         = "Deploy"
      owner            = "AWS"
      provider         = "ECS"
      input_artifacts  = ["build"]
      output_artifacts = []
      version          = "1"

      configuration = {
        ClusterName = var.ecs_cluster_name
        ServiceName = var.ecs_service_name_server
      }
    }
  }

  tags = local.tags
}

resource "aws_iam_role" "iam_role_codepipeline_server" {
  name = "${local.namespace}-server-codepipeline-role"

  assume_role_policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codebuild.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        },
        {
          "Effect" : "Allow",
          "Principal" : {
            "Service" : "codepipeline.amazonaws.com"
          },
          "Action" : "sts:AssumeRole"
        }
      ]
    })

  tags = local.tags
}

resource "aws_iam_policy" "iam_policy_policy_codepipeline_server" {
  name        = "${local.namespace}-server-codepipeline-policy"
  description = "Policy for CodePipeline"

  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : "iam:PassRole",
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:GetBucketVersioning",
            "s3:PutObjectAcl",
            "s3:PutObject",
          ],
          "Resource" : [
            aws_s3_bucket.s3_bucket_codepipeline.arn,
            "${aws_s3_bucket.s3_bucket_codepipeline.arn}/*",
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Resource" : [
            data.aws_secretsmanager_secret.secretsmanager_secret_registry.arn,
          ],
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:DescribeImages",
            "ecr:CompleteLayerUpload",
            "ecr:GetAuthorizationToken",
            "ecr:UploadLayerPart",
            "ecr:InitiateLayerUpload",
            "ecr:BatchCheckLayerAvailability",
            "ecr:PutImage"
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild"
          ],
          "Resource" : ["*"]
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "codedeploy:CreateDeployment",
            "codedeploy:GetApplicationRevision",
            "codedeploy:GetDeployment",
            "codedeploy:GetDeploymentConfig",
            "codedeploy:RegisterApplicationRevision"
          ],
          "Resource" : "*",
        },
        {
          "Effect" : "Allow",
          "Action" : [
            "ecs:DescribeServices",
            "ecs:DescribeTaskDefinition",
            "ecs:DescribeTasks",
            "ecs:ListTasks",
            "ecs:RegisterTaskDefinition",
            "ecs:TagResource",
            "ecs:UpdateService"
          ],
          "Resource" : "*",
        },
      ]
    })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_codepipeline_server" {
  role       = aws_iam_role.iam_role_codepipeline_server.name
  policy_arn = aws_iam_policy.iam_policy_policy_codepipeline_server.arn
}
