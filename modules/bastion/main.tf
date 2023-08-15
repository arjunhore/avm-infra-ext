locals {
  environment = var.environment
  namespace   = "avm-${var.environment}"

  tags = {
    Name        = local.namespace
    Environment = var.environment
  }
}

data "aws_subnets" "private_subnets" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    Name = "*private*"
  }
}

################################################################################
# EC2 Module
################################################################################

data "aws_ami" "amazon_linux_2_ssm" {
  most_recent = true

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

module "bastion" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.2"

  ami                         = var.ec2_bastion_ami_id != "" ? var.ec2_bastion_ami_id : data.aws_ami.amazon_linux_2_ssm.id
  name                        = "${local.namespace}-bastion"
  associate_public_ip_address = true
  instance_type               = "t2.micro"
  vpc_security_group_ids      = [module.security_group_bastion.security_group_id]
  subnet_id                   = element(data.aws_subnets.private_subnets.ids, 0)
  iam_instance_profile        = module.ec2_connect_role.iam_instance_profile_name

  metadata_options = {
    http_endpoint = "enabled" // Required for SSM
    http_tokens   = "required"
  }
}

module "security_group_bastion" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name            = "${local.namespace}-bastion-sg"
  description     = "Allow SSH inbound traffic for Bastion instance"
  vpc_id          = var.vpc_id
  use_name_prefix = false

  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["http-80-tcp", "https-443-tcp", "postgresql-tcp"]

  tags = local.tags
}

module ec2_connect_role {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.28"

  role_name               = "${local.namespace}-ec2-connect-role"
  role_requires_mfa       = false
  create_role             = true
  create_instance_profile = true

  trusted_role_services   = ["ec2.amazonaws.com"]
  custom_role_policy_arns = [
    "arn:aws:iam::aws:policy/EC2InstanceConnect",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "cloudwatch_alarm_cpu_usage" {
  alarm_name          = "${local.namespace}-bastion-cpu-usage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.ec2_cpu_usage_threshold

  alarm_actions = [var.sns_topic_alerts_arn]
  ok_actions    = [var.sns_topic_alerts_arn]

  dimensions = {
    InstanceId = module.bastion.id
  }

  tags = local.tags
}
