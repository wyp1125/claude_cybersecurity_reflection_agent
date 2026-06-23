terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "bdx-agentic-ai"
    key    = "terraform/bedrock-agent/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  agent_name   = "cybersecurity-reflection-agent-bedrock"
  foundation_model = "anthropic.claude-haiku-4-5-20251001-v1:0"
  account_id   = "925680695682"
}

# ── IAM role for the Bedrock Agent ────────────────────────────────────────────

data "aws_iam_policy_document" "bedrock_agent_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "bedrock_agent" {
  name               = "${local.agent_name}-role"
  assume_role_policy = data.aws_iam_policy_document.bedrock_agent_trust.json
}

data "aws_iam_policy_document" "bedrock_agent_permissions" {
  statement {
    sid     = "InvokeFoundationModel"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:us-east-1::foundation-model/${local.foundation_model}",
    ]
  }
}

resource "aws_iam_role_policy" "bedrock_agent" {
  name   = "bedrock-invoke-model"
  role   = aws_iam_role.bedrock_agent.id
  policy = data.aws_iam_policy_document.bedrock_agent_permissions.json
}

# ── Bedrock Agent ──────────────────────────────────────────────────────────────

resource "aws_bedrockagent_agent" "cybersecurity" {
  agent_name              = local.agent_name
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = local.foundation_model
  idle_session_ttl_in_seconds = 600

  instruction = "you are a helpful cybersecurity assistant specializing in mapping cybersecurity issues to nist 800.53 security and privacy controls"

  depends_on = [aws_iam_role_policy.bedrock_agent]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "agent_id" {
  description = "Set as BEDROCK_AGENT_ID when invoking agent.py"
  value       = aws_bedrockagent_agent.cybersecurity.agent_id
}

# TSTALIASID is the built-in alias AWS creates for every agent's DRAFT version.
output "agent_alias_id" {
  description = "Set as BEDROCK_AGENT_ALIAS_ID when invoking agent.py (built-in DRAFT alias)"
  value       = "TSTALIASID"
}
