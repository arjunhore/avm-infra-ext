locals {
  environment = var.environment
  namespace   = "avm-${var.environment}"

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

################################################################################
# Vanta Module
################################################################################

resource "aws_iam_policy" "VantaAdditionalPermissions" {
  name        = "VantaAdditionalPermissions"
  description = "Custom Vanta Policy"
  policy      = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Deny",
        "Action" : [
          "datapipeline:EvaluateExpression",
          "datapipeline:QueryObjects",
          "rds:DownloadDBLogFilePortion"
        ],
        "Resource" : "*"
      }
    ]
  })
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      identifiers = ["956993596390"]
      type        = "AWS"
    }
    condition {
      test     = "StringEquals"
      values   = ["0082C0B99FDD59F"]
      variable = "sts:ExternalId"
    }
  }
}

resource "aws_iam_role" "vanta_auditor" {
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  name               = "vanta-auditor"
}

resource "aws_iam_role_policy_attachment" "VantaSecurityAudit" {
  role       = aws_iam_role.vanta_auditor.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "VantaAdditionalPermissions" {
  role       = aws_iam_role.vanta_auditor.name
  policy_arn = aws_iam_policy.VantaAdditionalPermissions.arn
}
