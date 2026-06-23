terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  account_id    = "925680695682"
  oidc_provider = "token.actions.githubusercontent.com"
  github_repo   = "wyp1125/claude_cybersecurity_reflection_agent"
  role_name     = "github_actions_claude_cybersecurity_reflection_agent_role"
}

# ── GitHub Actions OIDC role ───────────────────────────────────────────────────

data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.account_id}:oidc-provider/${local.oidc_provider}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider}:sub"
      values   = ["repo:${local.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust.json
}

# ── Permissions needed by the CI/CD workflow ───────────────────────────────────

data "aws_iam_policy_document" "github_actions_permissions" {
  # IAM — create, manage, and pass roles (for Terraform to provision AgentCore role)
  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/*"]
  }

  # ECR — create repo and push images
  statement {
    sid    = "ECRRepositoryManagement"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:GetLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:TagResource",
      "ecr:ListTagsForResource",
    ]
    resources = ["arn:aws:ecr:us-east-1:${local.account_id}:repository/*"]
  }

  statement {
    sid    = "ECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRImagePush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:BatchDeleteImage",
    ]
    resources = ["arn:aws:ecr:us-east-1:${local.account_id}:repository/*"]
  }

  # CloudFormation — for AgentCore runtime stack
  statement {
    sid    = "CloudFormationManagement"
    effect = "Allow"
    actions = [
      "cloudformation:CreateStack",
      "cloudformation:UpdateStack",
      "cloudformation:DeleteStack",
      "cloudformation:DescribeStacks",
      "cloudformation:DescribeStackEvents",
      "cloudformation:DescribeStackResource",
      "cloudformation:GetTemplate",
      "cloudformation:ValidateTemplate",
      "cloudformation:CreateChangeSet",
      "cloudformation:ExecuteChangeSet",
      "cloudformation:DescribeChangeSet",
      "cloudformation:DeleteChangeSet",
    ]
    resources = ["*"]
  }

  # S3 — Terraform remote state backend
  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::bdx-agentic-ai",
      "arn:aws:s3:::bdx-agentic-ai/*",
    ]
  }

  # Bedrock AgentCore — create and manage agent runtimes
  statement {
    sid    = "BedrockAgentCore"
    effect = "Allow"
    actions = [
      "bedrock:*",
    ]
    resources = ["*"]
  }

  # CloudWatch Logs — AgentCore runtime logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogDelivery",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup",
      "logs:TagLogGroup",
      "logs:PutRetentionPolicy",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "github_actions_cicd_policy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "role_arn" {
  description = "ARN to set as the AWS_ROLE_ARN Actions variable in the repo"
  value       = aws_iam_role.github_actions.arn
}
