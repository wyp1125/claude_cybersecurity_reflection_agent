import json
import sys
import uuid

import boto3

# Ensure Unicode output works on Windows terminals
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

RUNTIME_NAME = "cybersecurity_reflection_agent"
REGION = "us-east-1"

_control_client = boto3.client("bedrock-agentcore-control", region_name=REGION)
_runtime_client = boto3.client("bedrock-agentcore", region_name=REGION)


def _get_runtime_arn(runtime_name: str) -> str:
    """Look up the AgentCore runtime ARN by name."""
    response = _control_client.list_agent_runtimes()
    for runtime in response.get("agentRuntimes", []):
        if runtime["agentRuntimeName"] == runtime_name:
            return runtime["agentRuntimeArn"]
    raise ValueError(f"AgentCore runtime '{runtime_name}' not found in {REGION}")


def invoke(input_text: str, session_id: str | None = None) -> dict:
    """Invoke the AgentCore runtime and return the parsed response."""
    if session_id is None:
        session_id = str(uuid.uuid4())

    runtime_arn = _get_runtime_arn(RUNTIME_NAME)

    response = _runtime_client.invoke_agent_runtime(
        agentRuntimeArn=runtime_arn,
        runtimeSessionId=session_id,
        payload=json.dumps({"inputText": input_text}).encode(),
    )

    raw = response["response"].read()
    return json.loads(raw)


if __name__ == "__main__":
    issue = input("Describe your cybersecurity issue: ").strip()
    if not issue:
        print("No input provided.")
    else:
        result = invoke(issue)
        print("\n--- NIST 800-53 Mapping ---")
        print(result.get("response", result))
        if "score" in result:
            print(f"\nScore: {result['score']}/5  |  Rounds: {result['rounds']}")
