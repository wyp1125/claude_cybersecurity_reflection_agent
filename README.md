# claude_cybersecurity_reflection_agent

A cybersecurity assistant that maps cybersecurity issues to NIST 800-53 security and privacy controls using Amazon Bedrock Agents and Claude Haiku 4.5.

## Architecture

```
GitHub Actions → Terraform → Amazon Bedrock Agent (Claude Haiku 4.5)
                                        ↓
                             invoke_agents/invoke_bedrock_agent.py
                             (local invocation client)
```

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | With Bedrock model access for `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| S3 bucket | `bdx-agentic-ai` — Terraform state stored at `terraform/bedrock-agent/terraform.tfstate` |
| GitHub OIDC | OIDC provider `token.actions.githubusercontent.com` registered in AWS account |
| GitHub variable | `AWS_ROLE_ARN` set in **Settings → Secrets and variables → Actions → Variables** |

## Setup

### 1. Deploy the bootstrap IAM role (one-time, manual)

Creates the IAM role GitHub Actions uses to authenticate via OIDC:

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Copy the `role_arn` output and set it as a GitHub Actions repository variable:

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::925680695682:role/github_actions_claude_cybersecurity_reflection_agent_role` |

### 2. Push to main

The `deploy_bedrock_agent` GitHub Actions workflow automatically runs `terraform apply` to provision the Bedrock Agent in AWS. It triggers on any change to `terraform/bedrock_agent/**`.

## Invoking the agent locally

```bash
pip install boto3
python invoke_agents/invoke_bedrock_agent.py
```

```
Describe your cybersecurity issue: SQL injection in our login endpoint
```

The script auto-discovers the agent ID from AWS by name — no environment variables required. AWS credentials must be configured in your environment (e.g. `~/.aws/credentials` or environment variables).

## Project structure

```
├── invoke_agents/
│   └── invoke_bedrock_agent.py   # Local client to invoke the deployed Bedrock Agent
├── terraform/
│   ├── bootstrap/
│   │   └── main.tf               # One-time: GitHub Actions OIDC IAM role
│   └── bedrock_agent/
│       └── main.tf               # Bedrock Agent, IAM role, and outputs
└── .github/workflows/
    ├── deploy.yml                 # AgentCore runtime CI/CD (future use)
    └── deploy_bedrock_agent.yml   # Bedrock Agent CI/CD: plan on PR, apply on main
```

## Notes

- **Model access**: Enable `us.anthropic.claude-haiku-4-5-20251001-v1:0` (cross-region inference profile) in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess) before deploying.
- **Bootstrap state**: `terraform/bootstrap/` uses local Terraform state and is excluded from version control (except `main.tf`). Run it once manually before any CI/CD workflows.
- **DRAFT alias**: The agent is invoked via the built-in `TSTALIASID` alias, which always points to the latest DRAFT version. No separate alias resource is needed.
