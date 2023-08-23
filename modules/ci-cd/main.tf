locals {
  region              = var.region
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_caller_identity" "current" {}

data "aws_secretsmanager_secret" "secretsmanager_secret_webapp" {
  name = var.secretsmanager_secret_id_webapp
}

data "aws_s3_bucket" "s3_bucket_webapp" {
  bucket = var.s3_bucket_name_webapp
}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "s3_bucket_codepipeline_web" {
  bucket = "${local.workspace_namespace}-web-codepipeline"
}

################################################################################
# CodePipeline Resources
################################################################################

resource "aws_codebuild_project" "codebuild_project_web" {
  name         = "${local.namespace}-web-codebuild"
  service_role = aws_iam_role.iam_role_codepipeline.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec.yml")
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
      group_name = "${local.namespace}-web-codebuild"
    }
  }

  tags = local.tags
}

resource "aws_codepipeline" "aws_codepipeline_web" {
  name     = "${local.namespace}-web-codepipeline"
  role_arn = aws_iam_role.iam_role_codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.s3_bucket_codepipeline_web.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "ECR"
      input_artifacts  = []
      output_artifacts = ["source"]
      version          = "1"

      configuration = {
        "RepositoryName" : split("/", module.ecr.repository_url)[1],
        "ImageTag" : "latest"
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
        ProjectName = aws_codebuild_project.codebuild_project_web.name
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
            name : "ECR_REGISTRY",
            value : split("/", module.ecr.repository_url)[0],
            type : "PLAINTEXT"
          },
          {
            name : "ECR_IMAGE_URI",
            value : "${module.ecr.repository_url}:latest",
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
}

resource "aws_iam_role" "iam_role_codepipeline" {
  name = "${local.namespace}-web-codepipeline-role"

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
}

resource "aws_iam_policy" "iam_policy_policy_codepipeline" {
  name        = "${local.namespace}-web-codepipeline-policy"
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
          "Action" : [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:GetBucketVersioning",
            "s3:PutObjectAcl",
            "s3:PutObject",
          ],
          "Effect" : "Allow",
          "Resource" : [
            aws_s3_bucket.s3_bucket_codepipeline_web.arn,
            "${aws_s3_bucket.s3_bucket_codepipeline_web.arn}/*",
            data.aws_s3_bucket.s3_bucket_webapp.arn,
            "${data.aws_s3_bucket.s3_bucket_webapp.arn}/*",
          ],
        },
        {
          "Action" : [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:DescribeImages",
          ],
          "Effect" : "Allow",
          "Resource" : ["*"]
        },
        {
          "Action" : [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild",
          ],
          "Effect" : "Allow",
          "Resource" : ["*"]
        },
        {
          "Action" : [
            "secretsmanager:GetResourcePolicy",
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret",
            "secretsmanager:ListSecretVersionIds"
          ],
          "Effect" : "Allow",
          "Resource" : [
            data.aws_secretsmanager_secret.secretsmanager_secret_webapp.arn
          ],
        }
      ]
    })
}

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_codepipeline" {
  role       = aws_iam_role.iam_role_codepipeline.name
  policy_arn = aws_iam_policy.iam_policy_policy_codepipeline.arn
}

################################################################################
# ECR Repository
################################################################################

module "ecr" {
  source = "terraform-aws-modules/ecr/aws"

  repository_name                   = "${local.namespace}-webapp"
  repository_read_write_access_arns = [data.aws_caller_identity.current.arn]
  create_lifecycle_policy           = false

  repository_image_tag_mutability = "MUTABLE"
  repository_encryption_type      = "KMS"
  repository_force_delete         = true

  tags = local.tags
}
