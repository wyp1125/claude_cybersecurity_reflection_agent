# NIST 800-53 Cybersecurity Assistant

A web-based chatbot that maps cybersecurity issues to NIST 800-53 security and privacy controls using Claude Haiku 4.5. The assistant uses a **reflection loop** — a generator–evaluator pattern that iteratively refines its analysis until the mapping reaches a quality score of 4/5 or higher (up to 5 rounds).

## Live Chatbot

**Sign in with Google → describe a cybersecurity issue → get a scored NIST 800-53 mapping.**

New Google accounts receive **2 free demo calls** automatically. No pre-registration required.

### How it works

1. You describe a cybersecurity issue (e.g. *"SQL injection on our login endpoint"*)
2. The **Generator** (Claude Haiku 4.5 via Bedrock) produces a NIST 800-53 control mapping — control IDs, names, and explanations
3. The **Evaluator** (same model, separate prompt) scores the mapping 1–5 and gives specific feedback
4. If the score is below 4, the feedback is passed back to the Generator for a revised mapping
5. The loop repeats up to **5 rounds**, stopping early once score ≥ 4
6. The final mapping, score, and round count are shown in the chat

Responses stream token-by-token in real time.

## Architecture

```
Browser (React + Vite)
  └── Google Sign-In → Cognito User Pool (OAuth 2.0)
        └── Cognito Identity Pool → STS AssumeRoleWithWebIdentity
              └── SigV4-signed POST → Lambda Function URL (AuthType = AWS_IAM)
                    └── stream_agent Lambda (Node.js 22, RESPONSE_STREAM)
                          ├── Verify Cognito JWT
                          ├── DynamoDB quota check / auto-provision demo calls
                          └── Bedrock reflection loop → SSE stream → browser
```

**Infrastructure is fully managed via Terraform + GitHub Actions CI/CD.**

```
push to main
  └── GitHub Actions (deploy_chatbot.yml)
        ├── terraform apply  (Cognito, Lambda, CloudFront, DynamoDB, IAM)
        ├── npm run build    (React chatbot)
        └── aws s3 sync + CloudFront invalidation
```

## Project Structure

```
├── chatbot/                        # React + Vite frontend
│   ├── src/
│   │   ├── App.jsx                 # Auth flow, config loading, routing
│   │   ├── Login.jsx               # Sign-in page with demo info
│   │   ├── Chat.jsx                # Chat UI with streaming + round status
│   │   ├── api.js                  # SigV4 signing, Cognito basic flow, SSE parsing
│   │   └── auth.js                 # Cognito hosted UI login/logout/callback
│   └── package.json
│
├── lambda/
│   ├── stream_agent/
│   │   └── index.mjs               # Reflection loop: JWT auth, quota, Bedrock streaming
│   └── pre_signup/
│       └── handler.py              # Cognito pre-signup trigger: auto-confirm all Google sign-ins
│
├── terraform/
│   ├── bootstrap/
│   │   └── main.tf                 # One-time: GitHub Actions OIDC IAM role
│   └── api_gateway/
│       └── main.tf                 # All chatbot infra: Cognito, Lambda, CloudFront, DynamoDB, IAM
│
└── .github/workflows/
    └── deploy_chatbot.yml      # CI/CD: terraform apply → build → S3 deploy → CloudFront invalidation
```

## Setup

### Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | Bedrock model access for `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| S3 bucket | `bdx-agentic-ai` — stores Terraform remote state |
| GitHub OIDC | `token.actions.githubusercontent.com` registered in your AWS account |
| Google OAuth | Google Cloud project with OAuth 2.0 client ID and secret |

### 1. Bootstrap IAM role (one-time, manual)

```bash
cd terraform/bootstrap
terraform init
terraform apply
```

Set the output as a GitHub Actions repository variable:

**Settings → Secrets and variables → Actions → Variables**

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | output of `terraform output github_actions_role_arn` |
| `GOOGLE_CLIENT_ID` | Google OAuth client ID |

**Settings → Secrets and variables → Actions → Secrets**

| Name | Value |
|---|---|
| `GOOGLE_CLIENT_SECRET` | Google OAuth client secret |

### 2. Deploy via CI/CD

Push to `main` (or any change under `lambda/**`, `terraform/api_gateway/**`, `chatbot/**`):

```
GitHub Actions → terraform apply → npm run build → s3 sync → CloudFront invalidation
```

PRs run `terraform plan` only (no apply).

### 3. Enable Bedrock model access

Enable `us.anthropic.claude-haiku-4-5-20251001-v1:0` (cross-region inference profile) in the [Bedrock console](https://console.aws.amazon.com/bedrock/home#/modelaccess) before deploying.

## Demo Quota

User quotas are tracked in DynamoDB. New users are **auto-provisioned** on their first API call — no pre-registration needed. The quota field uses `calls_remaining`:

| Value | Meaning |
|---|---|
| `2`, `1`, `0` | Demo user, calls remaining |
| `-1` | Unlimited (manually granted) |

To grant unlimited access to a user:

```bash
aws dynamodb update-item \
  --table-name <table-name> \
  --key '{"email": {"S": "user@example.com"}}' \
  --update-expression 'SET calls_remaining = :u' \
  --expression-attribute-values '{":u": {"N": "-1"}}'
```

## Key Implementation Notes

- **Lambda Function URLs + AWS_IAM**: requires **both** `lambda:InvokeFunctionUrl` AND `lambda:InvokeFunction` in the caller's policy. The IAM simulator only checks `InvokeFunctionUrl` and falsely reports ALLOW.
- **Cognito basic flow**: uses `GetOpenIdToken` + `STS.AssumeRoleWithWebIdentity` instead of the enhanced flow (`GetCredentialsForIdentity`). The enhanced flow injects a Cognito-managed session policy that silently blocks Lambda invocations at runtime. Requires `allow_classic_flow = true` on the Identity Pool.
- **SigV4 signing**: browser-side request signing uses `@smithy/signature-v4` + `@aws-crypto/sha256-browser` (same engine as AWS SDK v3) to avoid `InvalidSignatureException` with Lambda Function URLs.
- **Streaming**: Lambda uses `awslambda.streamifyResponse` with `invoke_mode = RESPONSE_STREAM`. The browser reads the SSE stream incrementally via the Fetch API `ReadableStream`.

---

## Earlier Experiments (reference only)

The repo also contains two earlier proof-of-concept deployments that are **not used by the chatbot**:

### Bedrock Agent (simple)

A basic Amazon Bedrock Agent with no reflection loop. Invoked locally via:

```bash
pip install boto3
python invoke_agents/invoke_bedrock_agent.py
```

Deployed by `.github/workflows/deploy_bedrock_agent.yml` → `terraform/bedrock_agent/`.

### Strands Agent on AgentCore

A Strands-based reflection agent packaged as an arm64 Docker image and deployed to Amazon AgentCore Runtime. Invoked locally via:

```bash
pip install boto3
python invoke_agents/invoke_strands_agent.py
```

Deployed by `.github/workflows/deploy_strands_agent.yml` → `terraform/agentcore/`.

> These are standalone scripts. The live chatbot does not call either of them.
