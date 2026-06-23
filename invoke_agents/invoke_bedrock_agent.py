import os
import uuid

import boto3

client = boto3.client("bedrock-agent-runtime", region_name="us-east-1")


def invoke(input_text: str, session_id: str | None = None) -> str:
    """Invoke the Bedrock Agent and return the full text response."""
    if session_id is None:
        session_id = str(uuid.uuid4())

    response = client.invoke_agent(
        agentId=os.environ["BEDROCK_AGENT_ID"],
        agentAliasId=os.environ.get("BEDROCK_AGENT_ALIAS_ID", "TSTALIASID"),
        sessionId=session_id,
        inputText=input_text,
    )

    output = ""
    for event in response["completion"]:
        if "chunk" in event:
            output += event["chunk"]["bytes"].decode("utf-8")
    return output


if __name__ == "__main__":
    print(invoke("What NIST 800-53 controls apply to SQL injection vulnerabilities?"))
