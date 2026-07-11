import json
import logging
import os
import uuid

import boto3
from boto3.dynamodb.conditions import Attr

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

REGION = os.environ.get("REGION", "us-east-1")
TABLE_NAME = os.environ["DYNAMODB_TABLE"]
RUNTIME_NAME = os.environ["AGENT_RUNTIME_NAME"]
UNLIMITED = -1

dynamodb = boto3.resource("dynamodb", region_name=REGION)
control_client = boto3.client("bedrock-agentcore-control", region_name=REGION)
runtime_client = boto3.client("bedrock-agentcore", region_name=REGION)

# Cache the runtime ARN across warm Lambda invocations
_runtime_arn_cache: dict[str, str] = {}


def _get_runtime_arn(name: str) -> str:
    if name not in _runtime_arn_cache:
        response = control_client.list_agent_runtimes()
        for r in response.get("agentRuntimes", []):
            if r["agentRuntimeName"] == name:
                _runtime_arn_cache[name] = r["agentRuntimeArn"]
                break
        else:
            raise ValueError(f"AgentCore runtime '{name}' not found")
    return _runtime_arn_cache[name]


def _check_and_decrement(email: str) -> tuple[bool, str | None]:
    """Return (allowed, error_message). Decrements counter unless calls_remaining == -1."""
    table = dynamodb.Table(TABLE_NAME)
    item = table.get_item(Key={"email": email}).get("Item")

    if item is None:
        return False, "Access denied"

    remaining = int(item.get("calls_remaining", 0))

    if remaining == UNLIMITED:
        return True, None

    if remaining <= 0:
        return False, "Call limit reached (5/5 used)"

    # Atomic decrement — only succeeds if still > 0 to prevent race conditions
    try:
        table.update_item(
            Key={"email": email},
            UpdateExpression="SET calls_remaining = calls_remaining - :one",
            ConditionExpression=Attr("calls_remaining").gt(0),
            ExpressionAttributeValues={":one": 1},
        )
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return False, "Call limit reached"

    return True, None


def handler(event, context):
    # Extract verified email from Cognito JWT claims (injected by API GW authorizer)
    claims = (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )
    email = claims.get("email", "")

    if not email:
        return _response(401, {"error": "Unauthorized"})

    # Parse request body
    try:
        body = json.loads(event.get("body") or "{}")
        input_text = body.get("inputText", "").strip()
    except (json.JSONDecodeError, AttributeError):
        return _response(400, {"error": "Invalid JSON body"})

    if not input_text:
        return _response(400, {"error": "inputText is required"})

    # Check quota and decrement atomically
    allowed, reason = _check_and_decrement(email)
    if not allowed:
        logger.warning("Quota check failed for email=%s reason=%s", email, reason)
        return _response(429, {"error": reason})

    logger.info("Invoking AgentCore runtime for email=%s", email)

    try:
        runtime_arn = _get_runtime_arn(RUNTIME_NAME)
        response = runtime_client.invoke_agent_runtime(
            agentRuntimeArn=runtime_arn,
            runtimeSessionId=str(uuid.uuid4()),
            payload=json.dumps({"inputText": input_text}).encode(),
        )
        result = json.loads(response["response"].read())
    except Exception as exc:
        logger.exception("AgentCore invocation failed")
        return _response(500, {"error": str(exc)})

    return _response(200, result)


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
