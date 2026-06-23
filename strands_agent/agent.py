import os

from bedrock_agentcore import BedrockAgentCoreApp
from strands import Agent
from strands.models.bedrock import BedrockModel

SYSTEM_PROMPT = (
    "You are a cybersecurity assistant that maps cybersecurity issues to NIST 800-53 "
    "security and privacy controls. When given any cybersecurity issue, immediately "
    "respond with the relevant NIST 800-53 controls. Do not ask clarifying questions. "
    "Work with whatever information is provided and output the most applicable controls "
    "with a brief explanation of why each control applies."
)

app = BedrockAgentCoreApp()

_agent = Agent(
    model=BedrockModel(
        model_id=os.environ.get(
            "BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"
        ),
    ),
    system_prompt=SYSTEM_PROMPT,
)


@app.entrypoint
def invoke(payload):
    result = _agent(payload.get("inputText", ""))
    return {"response": str(result)}


if __name__ == "__main__":
    app.run()
