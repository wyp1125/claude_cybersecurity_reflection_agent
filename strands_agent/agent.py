import json
import logging
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

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

_agent = Agent(
    model=BedrockModel(
        model_id=os.environ.get(
            "BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0"
        ),
    ),
    system_prompt=SYSTEM_PROMPT,
)


class AgentHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            result = _agent(body.get("inputText", ""))

            response = json.dumps({"response": str(result)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(response)
        except Exception as exc:
            logger.exception("Error handling request: %s", exc)
            self.send_response(500)
            self.end_headers()

    def log_message(self, fmt, *args):
        logger.info(fmt, *args)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    logger.info("Starting agent server on port %d", port)
    HTTPServer(("0.0.0.0", port), AgentHandler).serve_forever()
