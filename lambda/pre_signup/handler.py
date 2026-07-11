import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["DYNAMODB_TABLE"]


def handler(event, context):
    """Cognito pre-signup trigger: allow only emails pre-registered in DynamoDB."""
    email = (
        event.get("request", {})
        .get("userAttributes", {})
        .get("email", "")
    )
    logger.info("Pre-signup check for email=%s", email)

    if not email:
        raise Exception("Access denied: no email in request")

    table = dynamodb.Table(TABLE_NAME)
    item = table.get_item(Key={"email": email}).get("Item")

    if item is None:
        logger.warning("Rejected sign-up for unregistered email=%s", email)
        raise Exception(f"Access denied: {email} is not authorized")

    # Auto-confirm so the user doesn't need a separate email verification step
    event["response"]["autoConfirmUser"] = True
    event["response"]["autoVerifyEmail"] = True

    logger.info("Allowed sign-up for email=%s", email)
    return event
