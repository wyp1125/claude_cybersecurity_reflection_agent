import logging
import os
import re

from bedrock_agentcore import BedrockAgentCoreApp
from strands import Agent
from strands.models.bedrock import BedrockModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
MAX_ROUNDS = 5
SCORE_THRESHOLD = 4

GENERATOR_SYSTEM_PROMPT = (
    "You are a cybersecurity assistant that maps cybersecurity issues to NIST 800-53 "
    "security and privacy controls. When given a cybersecurity issue, immediately respond "
    "with the most relevant controls. Do not ask clarifying questions. "
    "For each control provide the control ID, name, and a brief explanation of why it applies. "
    "If given evaluator feedback from a previous round, incorporate it to improve your mapping."
)

EVALUATOR_SYSTEM_PROMPT = (
    "You are an expert evaluator of NIST 800-53 control mappings. "
    "Given a cybersecurity issue and a proposed set of controls, score the mapping "
    "on relevance and correctness using the following scale:\n"
    "  1 = Poor:      controls are largely irrelevant or incorrect\n"
    "  2 = Fair:      some relevant controls but significant gaps or errors\n"
    "  3 = Good:      mostly relevant controls with minor gaps\n"
    "  4 = Very Good: accurate and relevant with only minor improvements possible\n"
    "  5 = Excellent: comprehensive, accurate, and well-explained\n\n"
    "Reply in exactly this format:\n"
    "SCORE: <1-5>\n"
    "FEEDBACK: <specific feedback on gaps, errors, or confirmation if excellent>"
)

app = BedrockAgentCoreApp()


def _extract_score(text: str) -> int | None:
    match = re.search(r"SCORE:\s*([1-5])", text)
    return int(match.group(1)) if match else None


def _extract_feedback(text: str) -> str:
    match = re.search(r"FEEDBACK:\s*(.+)", text, re.DOTALL)
    return match.group(1).strip() if match else text.strip()


@app.entrypoint
def invoke(payload):
    logger.info("Received payload type=%s value=%r", type(payload).__name__, payload)

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
        return {"response": "Please provide a cybersecurity issue to map to NIST 800-53 controls."}

    model = BedrockModel(model_id=MODEL_ID)
    generator = Agent(model=model, system_prompt=GENERATOR_SYSTEM_PROMPT)
    evaluator = Agent(model=model, system_prompt=EVALUATOR_SYSTEM_PROMPT)

    mapping = None
    score = 0
    feedback = None

    for round_num in range(1, MAX_ROUNDS + 1):
        logger.info("Round %d/%d", round_num, MAX_ROUNDS)

        # ── Generate ────────────────────────────────────────────────────────────
        if feedback:
            gen_prompt = (
                f"Cybersecurity issue: {input_text}\n\n"
                f"Previous mapping:\n{mapping}\n\n"
                f"Evaluator feedback:\n{feedback}\n\n"
                "Improve your NIST 800-53 mapping based on this feedback."
            )
        else:
            gen_prompt = f"Cybersecurity issue: {input_text}"

        mapping = str(generator(gen_prompt))
        logger.info("Round %d mapping:\n%s", round_num, mapping)

        # ── Evaluate ────────────────────────────────────────────────────────────
        eval_prompt = (
            f"Cybersecurity issue: {input_text}\n\n"
            f"Proposed NIST 800-53 mapping:\n{mapping}"
        )
        eval_response = str(evaluator(eval_prompt))
        logger.info("Round %d evaluation:\n%s", round_num, eval_response)

        score = _extract_score(eval_response) or 0
        feedback = _extract_feedback(eval_response)
        logger.info("Round %d score: %d", round_num, score)

        if score >= SCORE_THRESHOLD:
            logger.info("Score %d reached threshold after %d round(s)", score, round_num)
            break

    return {
        "response": mapping,
        "score": score,
        "rounds": round_num,
    }


if __name__ == "__main__":
    app.run()
