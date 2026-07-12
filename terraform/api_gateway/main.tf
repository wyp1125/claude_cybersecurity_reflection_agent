terraform {
  backend "s3" {
    bucket = "bdx-agentic-ai"
    key    = "terraform/api-gateway/terraform.tfstate"
    region = "us-east-1"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  account_id   = "925680695682"
  region       = "us-east-1"
  project_name = "cybersecurity-reflection-agent"
  admin_email  = "wyp1125@gmail.com"
}

variable "google_client_id" {
  description = "Google OAuth2 client ID from Google Cloud Console"
  type        = string
}

variable "google_client_secret" {
  description = "Google OAuth2 client secret from Google Cloud Console"
  type        = string
  sensitive   = true
}

# ── DynamoDB: user access + call quota ────────────────────────────────────────

resource "aws_dynamodb_table" "user_access" {
  name         = "${local.project_name}-user-access"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "email"

  attribute {
    name = "email"
    type = "S"
  }
}

# Admin user (wyp1125@gmail.com) — calls_remaining = -1 means unlimited
resource "aws_dynamodb_table_item" "admin_user" {
  table_name = aws_dynamodb_table.user_access.name
  hash_key   = aws_dynamodb_table.user_access.hash_key

  item = jsonencode({
    email           = { S = local.admin_email }
    calls_remaining = { N = "-1" }
  })
}

# ── Lambda: pre-signup trigger ────────────────────────────────────────────────

data "archive_file" "pre_signup" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/pre_signup/handler.py"
  output_path = "${path.module}/../../lambda/pre_signup/handler.zip"
}

resource "aws_iam_role" "pre_signup_lambda" {
  name = "${local.project_name}-pre-signup-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pre_signup_lambda" {
  name = "pre_signup_lambda_policy"
  role = aws_iam_role.pre_signup_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.user_access.arn
      }
    ]
  })
}

resource "aws_lambda_function" "pre_signup" {
  function_name    = "${local.project_name}-pre-signup"
  role             = aws_iam_role.pre_signup_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.pre_signup.output_path
  source_code_hash = data.archive_file.pre_signup.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.user_access.name
    }
  }
}

resource "aws_lambda_permission" "cognito_pre_signup" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pre_signup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.main.arn
}

# ── Lambda: invoke strands agent ──────────────────────────────────────────────

data "archive_file" "invoke_strands" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/invoke_strands_agent/handler.py"
  output_path = "${path.module}/../../lambda/invoke_strands_agent/handler.zip"
}

resource "aws_iam_role" "invoke_lambda" {
  name = "${local.project_name}-invoke-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "invoke_lambda" {
  name = "invoke_lambda_policy"
  role = aws_iam_role.invoke_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.user_access.arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore-control:ListAgentRuntimes"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "invoke_strands" {
  function_name    = "${local.project_name}-invoke"
  role             = aws_iam_role.invoke_lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.invoke_strands.output_path
  source_code_hash = data.archive_file.invoke_strands.output_base64sha256
  timeout          = 29

  environment {
    variables = {
      DYNAMODB_TABLE     = aws_dynamodb_table.user_access.name
      AGENT_RUNTIME_NAME = "cybersecurity_reflection_agent"
      REGION             = local.region
    }
  }
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.invoke_strands.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── Cognito User Pool ─────────────────────────────────────────────────────────

resource "aws_cognito_user_pool" "main" {
  name = "${local.project_name}-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  lambda_config {
    pre_sign_up = aws_lambda_function.pre_signup.arn
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${local.project_name}-auth"
  user_pool_id = aws_cognito_user_pool.main.id
}

# ── Google Identity Provider ──────────────────────────────────────────────────

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id            = var.google_client_id
    client_secret        = var.google_client_secret
    authorize_scopes     = "email openid profile"
    authorize_url        = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer          = "https://accounts.google.com"
    token_request_method = "POST"
    token_url            = "https://oauth2.googleapis.com/token"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

# ── Cognito App Client ────────────────────────────────────────────────────────

resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.project_name}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  supported_identity_providers         = ["Google"]
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  allowed_oauth_flows_user_pool_client = true
  generate_secret                      = false

  callback_urls = [
    "http://localhost:9999/callback",   # CLI invoke script
    "http://localhost:3000/callback",   # Local Vite dev server
    "https://${aws_cloudfront_distribution.chatbot.domain_name}/callback",  # Production
  ]
  logout_urls = [
    "http://localhost:9999/logout",
    "http://localhost:3000/logout",
    "https://${aws_cloudfront_distribution.chatbot.domain_name}/logout",
  ]

  depends_on = [aws_cognito_identity_provider.google]
}

# ── API Gateway HTTP API ──────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "main" {
  name          = local.project_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["authorization", "content-type"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = [
      "http://localhost:3000",
      "https://${aws_cloudfront_distribution.chatbot.domain_name}",
    ]
    max_age = 300
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "invoke" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.invoke_strands.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "invoke" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /invoke"
  target             = "integrations/${aws_apigatewayv2_integration.invoke.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

# ── Lambda: streaming agent (Node.js, Function URL with RESPONSE_STREAM) ─────

data "archive_file" "stream_agent" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/stream_agent"
  output_path = "${path.module}/../../lambda/stream_agent.zip"
}

resource "aws_iam_role" "stream_lambda" {
  name = "${local.project_name}-stream-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "stream_lambda" {
  name = "stream_lambda_policy"
  role = aws_iam_role.stream_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.user_access.arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "stream_agent" {
  function_name    = "${local.project_name}-stream"
  role             = aws_iam_role.stream_lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  filename         = data.archive_file.stream_agent.output_path
  source_code_hash = data.archive_file.stream_agent.output_base64sha256
  timeout          = 55

  environment {
    variables = {
      DYNAMODB_TABLE   = aws_dynamodb_table.user_access.name
      REGION           = local.region
      USER_POOL_ID     = aws_cognito_user_pool.main.id
      BEDROCK_MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
    }
  }
}

# Lambda Function URL — AWS_IAM auth. CloudFront OAC is NOT used here because
# OAC with custom_origin_config signs host:<domain>:443, but Lambda SigV4 auth
# verifies host:<domain> (no port), causing InvalidSignatureException.
# Instead, the browser obtains temporary credentials via Cognito Identity Pool
# and signs requests directly (correct host header, no CloudFront in the path).
resource "aws_lambda_function_url" "stream_agent" {
  function_name      = aws_lambda_function.stream_agent.function_name
  authorization_type = "AWS_IAM"
  invoke_mode        = "RESPONSE_STREAM"

  cors {
    allow_credentials = false
    allow_origins = [
      "http://localhost:3000",
      "https://${aws_cloudfront_distribution.chatbot.domain_name}",
    ]
    allow_methods = ["POST"]
    allow_headers = [
      "content-type",
      "authorization",
      "x-amz-content-sha256",
      "x-amz-date",
      "x-amz-security-token",
    ]
    expose_headers = ["x-amzn-errortype", "x-amzn-requestid"]
    max_age        = 300
  }
}

# Resource-based policy: allows the Cognito auth role to invoke the function URL.
# Lambda Function URLs with AuthType = AWS_IAM require BOTH an identity-based
# policy on the caller's role AND a resource-based policy on the function itself.
# The identity-based policy alone is insufficient for federated (Cognito) callers.
resource "aws_lambda_permission" "cognito_invoke_url" {
  statement_id  = "AllowAccountInvokeFunctionUrl"
  action        = "lambda:InvokeFunctionUrl"
  function_name = aws_lambda_function.stream_agent.function_name
  principal     = local.account_id
}

# ── Cognito Identity Pool (browser SigV4 signing for Lambda Function URL) ────
# Authenticated users get temporary IAM credentials to call the stream Lambda
# directly — bypassing CloudFront OAC whose host:443 signing breaks Lambda auth.

resource "aws_cognito_identity_pool" "main" {
  identity_pool_name               = "${local.project_name}-identity-pool"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.main.id
    provider_name           = "cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    server_side_token_check = false
  }
}

resource "aws_iam_role" "cognito_authenticated" {
  name = "${local.project_name}-cognito-auth-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "cognito-identity.amazonaws.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.main.id
        }
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cognito_authenticated" {
  name = "stream_lambda_invoke"
  role = aws_iam_role.cognito_authenticated.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunctionUrl"
      Resource = aws_lambda_function.stream_agent.arn
    }]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "main" {
  identity_pool_id = aws_cognito_identity_pool.main.id

  roles = {
    authenticated = aws_iam_role.cognito_authenticated.arn
  }
}

# ── S3 bucket for chatbot static files ───────────────────────────────────────

resource "aws_s3_bucket" "chatbot" {
  bucket = "${local.project_name}-chatbot-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "chatbot" {
  bucket                  = aws_s3_bucket.chatbot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CloudFront distribution ───────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "chatbot" {
  name                              = "${local.project_name}-chatbot"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}


resource "aws_cloudfront_distribution" "chatbot" {
  enabled             = true
  default_root_object = "index.html"

  # ── S3 origin (static chatbot files) ─────────────────────────────────────────
  origin {
    domain_name              = aws_s3_bucket.chatbot.bucket_regional_domain_name
    origin_id                = "s3-chatbot"
    origin_access_control_id = aws_cloudfront_origin_access_control.chatbot.id
  }

  # ── Default → S3 (static files) ───────────────────────────────────────────────
  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-chatbot"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # Route unknown S3 paths to index.html for React SPA routing.
  # S3 returns 403 (not 404) for non-existent keys when only s3:GetObject is
  # granted (no s3:ListBucket). Both 403 and 404 must be mapped. This is safe
  # now that the Lambda origin is gone — there are no Lambda 403s to mask.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "chatbot" {
  bucket = aws_s3_bucket.chatbot.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.chatbot.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.chatbot.arn
        }
      }
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "api_url" {
  description = "POST endpoint to invoke the agent"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/invoke"
}

output "cognito_domain" {
  description = "Cognito hosted UI base URL (needed for Google OAuth redirect URI)"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com"
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.main.id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.user_access.name
}

output "chatbot_bucket_name" {
  description = "S3 bucket where the React chatbot is deployed"
  value       = aws_s3_bucket.chatbot.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (needed for cache invalidation)"
  value       = aws_cloudfront_distribution.chatbot.id
}

output "cloudfront_url" {
  description = "HTTPS URL of the chatbot — add /callback to Google OAuth redirect URIs"
  value       = "https://${aws_cloudfront_distribution.chatbot.domain_name}"
}

output "stream_url" {
  description = "Lambda Function URL called directly by the browser with SigV4 (via Cognito Identity credentials)"
  value       = aws_lambda_function_url.stream_agent.function_url
}

output "identity_pool_id" {
  description = "Cognito Identity Pool ID — browser exchanges ID token for temp AWS credentials"
  value       = aws_cognito_identity_pool.main.id
}

output "region" {
  value = local.region
}
