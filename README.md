# claude_cybersecurity_reflection_agent

A reflection agent which can map cybersecurity issues to preventive controls using Claude, Bedrock, Strands Agents, and AgentCore.

## Architecture

```
GitHub Actions → ECR (Docker image) → Terraform → AgentCore Runtime
                                                        ↓
                                              Strands Agent (HTTP server)
                                                        ↓
                                              Amazon Bedrock (Claude Haiku 4.5)
```

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | With Bedrock model access for `anthropic.claude-haiku-4-5-20251001-v1:0` |
| S3 bucket | `bdx-agentic-ai` — Terraform state stored at `terraform/cybersecurity-reflection-agent/terraform.tfstate` |
| IAM user/role | With ECR, CloudFormation, IAM, and Bedrock permissions for CI/CD |
| GitHub secrets | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

## Quick start

### 1. Set GitHub secrets

In **Settings → Secrets and variables → Actions**:

- Secret `AWS_ACCESS_KEY_ID`
- Secret `AWS_SECRET_ACCESS_KEY`

### 3. Push to main

The GitHub Actions workflow automatically:
1. Provisions ECR repository and IAM role
2. Builds and pushes the Docker image
3. Creates/updates the AgentCore runtime via CloudFormation

### Local development

```bash
# Run the agent locally (requires AWS credentials and Bedrock access)
cd app
pip install -r requirements.txt
BEDROCK_MODEL_ID=anthropic.claude-haiku-4-5-20251001-v1:0 python server.py

# Test it
curl -s -X POST http://localhost:8080/ \
  -H 'Content-Type: application/json' \
  -d '{"inputText": "SQL injection vulnerability in our login endpoint"}' | jq .
```

### Local Terraform

```bash
cd terraform
terraform init
terraform plan -var="image_tag=latest"
```

## Invoking the deployed agent

After deployment, get the endpoint URL from Terraform outputs:

```bash
cd terraform
terraform output agentcore_endpoint_url
```

Then invoke via the AgentCore API:

```bash
aws bedrock-agentcore invoke-agent-runtime \
  --agent-runtime-id <runtime-id> \
  --region us-east-1 \
  --body '{"inputText": "Describe controls for preventing credential stuffing attacks"}'
```

## Project structure

```
├── app/
│   ├── server.py          # Strands agent + AgentCore HTTP server
│   ├── requirements.txt
│   └── Dockerfile
├── terraform/
│   ├── providers.tf       # AWS provider + S3 backend
│   ├── variables.tf
│   ├── ecr.tf             # ECR repository
│   ├── iam.tf             # AgentCore IAM role and policies
│   ├── agentcore.tf       # AgentCore runtime (CloudFormation)
│   └── outputs.tf
└── .github/workflows/
    └── deploy.yml         # CI/CD: plan on PR, build+deploy on main
```

## Notes

- **CloudFormation resource type**: `AWS::BedrockAgentCore::AgentRuntime` must be available in your region. Verify with:
  ```bash
  aws cloudformation describe-type --type RESOURCE \
    --type-name AWS::BedrockAgentCore::AgentRuntime
  ```
- **Model access**: Enable the Haiku model in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess) before deploying.
- **Image tag strategy**: Each push to `main` tags the image with the git SHA and also updates `latest`.
