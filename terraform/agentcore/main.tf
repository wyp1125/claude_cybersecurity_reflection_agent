terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "bdx-agentic-ai"
    key    = "terraform/agentcore/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "image_tag" {
  description = "Docker image tag to deploy (git SHA from CI)"
  type        = string
  default     = "latest"
}

locals {
  agent_name = "cybersecurity-reflection-agent"
  account_id = "925680695682"
  region     = "us-east-1"
  ecr_url    = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${local.agent_name}"
}

# ── ECR ───────────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "agent" {
  name                 = local.agent_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ── IAM role for AgentCore runtime ────────────────────────────────────────────

resource "aws_iam_role" "agentcore" {
  name = "${local.agent_name}-agentcore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_invoke" {
  name = "bedrock-invoke"
  role = aws_iam_role.agentcore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "ecr_pull" {
  name = "ecr-pull"
  role = aws_iam_role.agentcore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.agent.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "cloudwatch-logs"
  role = aws_iam_role.agentcore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
    }]
  })
}

# ── AgentCore runtime (CloudFormation) ────────────────────────────────────────

resource "aws_cloudformation_stack" "agentcore" {
  name = local.agent_name

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      AgentRuntime = {
        Type = "AWS::BedrockAgentCore::AgentRuntime"
        Properties = {
          AgentRuntimeName = local.agent_name
          Description      = "Cybersecurity NIST 800-53 control mapping agent"
          RoleArn          = aws_iam_role.agentcore.arn
          AgentRuntimeArtifact = {
            ContainerConfiguration = {
              ContainerUri = "${local.ecr_url}:${var.image_tag}"
            }
          }
        }
      }
    }
    Outputs = {
      AgentRuntimeId = {
        Description = "AgentCore runtime ID"
        Value       = { Ref = "AgentRuntime" }
      }
    }
  })

  depends_on = [
    aws_iam_role_policy.bedrock_invoke,
    aws_iam_role_policy.ecr_pull,
    aws_iam_role_policy.cloudwatch_logs,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  value = aws_ecr_repository.agent.repository_url
}

output "agentcore_runtime_id" {
  value = aws_cloudformation_stack.agentcore.outputs["AgentRuntimeId"]
}
