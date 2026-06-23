# claude_cybersecurity_reflection_agent

A cybersecurity assistant that maps cybersecurity issues to NIST 800-53 security and privacy controls using Claude Haiku 4.5. Two deployment targets are provided: a simple Amazon Bedrock Agent and a Strands-based reflection agent deployed to AgentCore.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Bedrock Agent (simple)                                         │
│                                                                 │
│  GitHub Actions → Terraform → Amazon Bedrock Agent             │
│                                    ↓                           │
│                       invoke_agents/invoke_bedrock_agent.py    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Strands Agent with reflection loop (AgentCore)                 │
│                                                                 │
│  GitHub Actions → ECR (arm64 image) → AgentCore Runtime        │
│                                           ↓                    │
│                    ┌──────────────────────────────────────┐    │
│                    │  Reflection Loop (max 5 rounds)       │    │
│                    │  Generator → NIST 800-53 mapping      │    │
│                    │  Evaluator → score 1-5 + feedback     │    │
│                    │  Loop until score ≥ 4                 │    │
│                    └──────────────────────────────────────┘    │
│                                           ↓                    │
│                       invoke_agents/invoke_strands_agent.py    │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | With Bedrock model access for `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| S3 bucket | `bdx-agentic-ai` — stores Terraform state for both agents |
| GitHub OIDC | OIDC provider `token.actions.githubusercontent.com` registered in AWS account |
| GitHub variable | `AWS_ROLE_ARN` set under **Settings → Secrets and variables → Actions → Variables** |

## Setup

### 1. Deploy the bootstrap IAM role (one-time, manual)

Creates the GitHub Actions OIDC role with permissions for ECR, IAM, Bedrock, and AgentCore:

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Set the output as a GitHub Actions repository variable:

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::925680695682:role/github_actions_claude_cybersecurity_reflection_agent_role` |

### 2. Deploy via CI/CD

Each agent has its own workflow triggered by changes to its relevant paths:

| Workflow | Trigger paths | What it does |
|---|---|---|
| `deploy_bedrock_agent.yml` | `terraform/bedrock_agent/**` | `terraform apply` — provisions the Bedrock Agent |
| `deploy_strands_agent.yml` | `strands_agent/**`, `terraform/agentcore/**`, `.github/workflows/deploy_strands_agent.yml` | Terraform (ECR + IAM) → build & push arm64 Docker image → create/update AgentCore runtime via AWS CLI |

Both workflows run `terraform plan` on PRs and apply on push to `main`.

## Invoking the agents locally

Requires AWS credentials configured in your environment (`~/.aws/credentials` or environment variables). Both scripts auto-discover resource IDs/ARNs by name — no manual configuration needed.

### Bedrock Agent

```bash
pip install boto3
python invoke_agents/invoke_bedrock_agent.py
```

```
Describe your cybersecurity issue: SQL injection in our login endpoint
AC-3: Access Enforcement — ...
SI-10: Information Input Validation — ...
```

### Strands Agent (reflection loop)

```bash
pip install boto3
python invoke_agents/invoke_strands_agent.py
```

```
Describe your cybersecurity issue: an employee lost the company laptop
--- NIST 800-53 Mapping ---
...
Score: 4/5  |  Rounds: 2
```

## Project structure

```
├── invoke_agents/
│   ├── invoke_bedrock_agent.py    # Local client for the Bedrock Agent
│   └── invoke_strands_agent.py    # Local client for the AgentCore runtime
├── strands_agent/
│   ├── agent.py                   # Strands agent with generator/evaluator reflection loop
│   ├── Dockerfile                 # arm64 container image
│   └── requirements.txt
├── terraform/
│   ├── bootstrap/
│   │   └── main.tf                # One-time: GitHub Actions OIDC IAM role
│   ├── bedrock_agent/
│   │   └── main.tf                # Bedrock Agent + IAM role (S3 state: terraform/bedrock-agent/)
│   └── agentcore/
│       └── main.tf                # ECR repository + AgentCore IAM role (S3 state: terraform/agentcore/)
└── .github/workflows/
    ├── deploy_bedrock_agent.yml   # Bedrock Agent CI/CD
    └── deploy_strands_agent.yml   # Strands Agent CI/CD (build + AgentCore deploy)
```

## Reflection loop

The Strands agent uses a generator–evaluator pattern to iteratively improve NIST 800-53 mappings:

1. **Generator** maps the cybersecurity issue to relevant NIST 800-53 controls
2. **Evaluator** scores the mapping 1–5 on relevance and correctness and provides specific feedback
3. If score < 4, the feedback is passed back to the generator for a revised mapping
4. The loop repeats up to **5 rounds**, stopping early when score ≥ 4

The response includes the final mapping, the score, and the number of rounds taken.

## Notes

- **Model access**: Enable `us.anthropic.claude-haiku-4-5-20251001-v1:0` (cross-region inference profile) in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess) before deploying.
- **Bootstrap state**: `terraform/bootstrap/` uses local Terraform state (excluded from version control). Run it once manually before any CI/CD workflows.
- **AgentCore requires arm64**: The Docker image is built with `--platform linux/arm64` via QEMU emulation on the GitHub Actions runner.
- **AgentCore runtime name**: The runtime name uses underscores (`cybersecurity_reflection_agent`) since AgentCore does not allow hyphens in runtime names.
- **Bedrock Agent alias**: Invoked via the built-in `TSTALIASID` alias (always points to the DRAFT version). No custom alias resource is needed.
