locals {
  region              = var.region
  environment         = var.environment
  namespace           = "avm-${var.environment}"
  workspace_namespace = "avm-${terraform.workspace}-${var.environment}"

  ecr_repository_name_webapp = split("/", var.ecr_repository_url_webapp)[1]
  ecr_repository_name_server = split("/", var.ecr_repository_url_server)[1]

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

data "aws_ecr_repository" "ecr_repository_webapp" {
  name = local.ecr_repository_name_webapp
}

data "aws_ecr_repository" "ecr_repository_server" {
  name = local.ecr_repository_name_server
}

################################################################################
# S3
################################################################################

resource "aws_s3_bucket" "s3_bucket_codepipeline" {
  bucket = "${local.workspace_namespace}-codepipeline"
}

################################################################################
# CodePipeline Resources
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
      provider         = "ECR"
      input_artifacts  = []
      output_artifacts = ["source"]
      version          = "1"

      configuration = {
        "RepositoryName" : local.ecr_repository_name_webapp,
        "ImageTag" : var.ecr_repository_image_tag
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
            name : "ECR_REGISTRY",
            value : split("/", data.aws_ecr_repository.ecr_repository_webapp.repository_url)[0],
            type : "PLAINTEXT"
          },
          {
            name : "ECR_IMAGE_URI",
            value : "${data.aws_ecr_repository.ecr_repository_webapp.repository_url}:${var.ecr_repository_image_tag}",
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
          "Action" : [
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:GetBucketVersioning",
            "s3:PutObjectAcl",
            "s3:PutObject",
          ],
          "Effect" : "Allow",
          "Resource" : [
            aws_s3_bucket.s3_bucket_codepipeline.arn,
            "${aws_s3_bucket.s3_bucket_codepipeline.arn}/*",
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

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_codepipeline_webapp" {
  role       = aws_iam_role.iam_role_codepipeline_webapp.name
  policy_arn = aws_iam_policy.iam_policy_policy_codepipeline_webapp.arn
}

################################################################################
# ECR Repository
################################################################################

resource "aws_ecr_registry_policy" "this" {
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "ReplicationAccessCrossAccount",
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::${var.aws_account_id_root}:root"
        },
        "Action" : [
          "ecr:CreateRepository",
          "ecr:ReplicateImage"
        ],
        "Resource" : "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })
}
