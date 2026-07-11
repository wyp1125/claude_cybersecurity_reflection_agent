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

  # Bedrock — agents, models, inference profiles
  statement {
    sid    = "Bedrock"
    effect = "Allow"
    actions = [
      "bedrock:*",
    ]
    resources = ["*"]
  }

  # Bedrock AgentCore — create and manage agent runtimes
  statement {
    sid    = "BedrockAgentCore"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:*",
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

  # DynamoDB — user access / quota table
  statement {
    sid    = "DynamoDB"
    effect = "Allow"
    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:UpdateTable",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:ListTagsOfResource",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = ["arn:aws:dynamodb:us-east-1:${local.account_id}:table/*"]
  }

  # Lambda — pre-signup trigger and invoke function
  statement {
    sid    = "Lambda"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:DeleteFunction",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:TagResource",
      "lambda:ListTags",
      "lambda:CreateFunctionUrlConfig",
      "lambda:UpdateFunctionUrlConfig",
      "lambda:DeleteFunctionUrlConfig",
      "lambda:GetFunctionUrlConfig",
      "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig",
    ]
    resources = ["arn:aws:lambda:us-east-1:${local.account_id}:function:*"]
  }

  # API Gateway HTTP API
  statement {
    sid    = "APIGateway"
    effect = "Allow"
    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:PATCH",
      "apigateway:DELETE",
      "apigateway:TagResource",
      "apigateway:UntagResource",
    ]
    resources = ["arn:aws:apigateway:us-east-1::*"]
  }

  # S3 — chatbot static files bucket (separate from Terraform state bucket)
  statement {
    sid    = "ChatbotS3Bucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLocation",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:ListBucket",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:Get*",
      "s3:List*",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
    ]
    resources = [
      "arn:aws:s3:::cybersecurity-reflection-agent-chatbot-*",
      "arn:aws:s3:::cybersecurity-reflection-agent-chatbot-*/*",
    ]
  }

  # CloudFront — chatbot distribution
  statement {
    sid    = "CloudFront"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = ["*"]
  }

  # Cognito — user pool, identity providers, app clients
  statement {
    sid    = "Cognito"
    effect = "Allow"
    actions = [
      "cognito-idp:Get*",
      "cognito-idp:Describe*",
      "cognito-idp:List*",
      "cognito-idp:CreateUserPool",
      "cognito-idp:DeleteUserPool",
      "cognito-idp:UpdateUserPool",
      "cognito-idp:CreateUserPoolDomain",
      "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:CreateUserPoolClient",
      "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:CreateIdentityProvider",
      "cognito-idp:DeleteIdentityProvider",
      "cognito-idp:UpdateIdentityProvider",
      "cognito-idp:TagResource",
      "cognito-idp:UntagResource",
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
