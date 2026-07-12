import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["DYNAMODB_TABLE"]


def handler(event, context):
    """Cognito pre-signup trigger: auto-confirm all Google sign-ins.
    Per-user quota is enforced by the streaming Lambda via DynamoDB."""
    email = (
        event.get("request", {})
        .get("userAttributes", {})
        .get("email", "")
    )
    logger.info("Pre-signup for email=%s", email)

    event["response"]["autoConfirmUser"] = True
    event["response"]["autoVerifyEmail"] = True
    return event
