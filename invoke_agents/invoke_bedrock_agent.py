import uuid

import boto3

AGENT_NAME = "cybersecurity-reflection-agent-bedrock"
REGION = "us-east-1"

_agent_client = boto3.client("bedrock-agent", region_name=REGION)
_runtime_client = boto3.client("bedrock-agent-runtime", region_name=REGION)


def _get_agent_id(agent_name: str) -> str:
    """Look up the agent ID by name from AWS."""
    paginator = _agent_client.get_paginator("list_agents")
    for page in paginator.paginate():
        for agent in page["agentSummaries"]:
            if agent["agentName"] == agent_name:
                return agent["agentId"]
    raise ValueError(f"Bedrock Agent '{agent_name}' not found in {REGION}")


def invoke(input_text: str, session_id: str | None = None) -> str:
    """Invoke the Bedrock Agent and return the full text response."""
    if session_id is None:
        session_id = str(uuid.uuid4())

    response = _runtime_client.invoke_agent(
        agentId=_get_agent_id(AGENT_NAME),
        agentAliasId="TSTALIASID",
        sessionId=session_id,
        inputText=input_text,
    )

    output = ""
    for event in response["completion"]:
        if "chunk" in event:
            output += event["chunk"]["bytes"].decode("utf-8")
    return output


if __name__ == "__main__":
    issue = input("Describe your cybersecurity issue: ").strip()
    if not issue:
        print("No input provided.")
    else:
        print(invoke(issue))
