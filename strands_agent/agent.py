import logging
import os

from bedrock_agentcore import BedrockAgentCoreApp
from strands import Agent
from strands.models.bedrock import BedrockModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

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
    logger.info("Received payload type=%s value=%r", type(payload).__name__, payload)

    # BedrockAgentCoreApp may pass the input as a plain string or as a dict
    if isinstance(payload, str):
        input_text = payload
    elif isinstance(payload, dict):
        input_text = (
            payload.get("inputText")
            or payload.get("prompt")
            or payload.get("input")
            or payload.get("text")
            or ""
        )
    else:
        input_text = str(payload)

    if not input_text:
        logger.warning("Empty input received; payload=%r", payload)
        return {"response": "Please provide a cybersecurity issue to map to NIST 800-53 controls."}

    result = _agent(input_text)
    return {"response": str(result)}


if __name__ == "__main__":
    app.run()
