"""Bot Framework messaging endpoint for Teams agents.

Receives messages from Teams via Bot Framework, calls the APIM /chat endpoint,
and sends the response back to the user.
"""

import json
import logging
import os
import re
import sys
from pathlib import Path

import aiohttp
import azure.functions as func
from botbuilder.core import BotFrameworkAdapter, BotFrameworkAdapterSettings, TurnContext
from botbuilder.schema import Activity

PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import config

APIM_CHAT_URL = os.environ.get(
    "APIM_CHAT_URL",
    "https://ai-gateway-apim-poc-my.azure-api.net/foundry-privatevnet-app/chat",
)
BOT_APP_ID = os.environ.get("MicrosoftAppId", "")
BOT_APP_PASSWORD = os.environ.get("MicrosoftAppPassword", "")

_settings = BotFrameworkAdapterSettings(BOT_APP_ID, BOT_APP_PASSWORD)
_adapter = BotFrameworkAdapter(_settings)


def _normalize_words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def _extract_prompt(activity: Activity) -> str:
    if isinstance(activity.text, str) and activity.text.strip():
        return activity.text.strip()

    value = getattr(activity, "value", None)
    if isinstance(value, dict):
        for key in ("prompt", "text", "query", "message"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip()

    return ""


def _infer_use_case(activity: Activity, prompt: str) -> str:
    configured_use_case = os.environ.get("USE_CASE")
    if configured_use_case in config.VALID_USE_CASES:
        return configured_use_case

    haystacks = {
        use_case: " ".join(
            [entry["text"] for entry in config.prompts_config()["use_cases"][use_case]["agent"]]
            + [doc["title"] for doc in config.document_config()["use_cases"][use_case]["sample_documents"]]
            + [doc["filename"] for doc in config.document_config()["use_cases"][use_case]["sample_documents"]]
        )
        for use_case in config.VALID_USE_CASES
    }

    prompt_words = _normalize_words(prompt)
    if not prompt_words:
        return config.DEFAULT_USE_CASE

    best_use_case = config.DEFAULT_USE_CASE
    best_score = -1
    for use_case, haystack in haystacks.items():
        score = len(prompt_words & _normalize_words(haystack))
        if score > best_score:
            best_use_case = use_case
            best_score = score

    return best_use_case


async def _on_message(turn_context: TurnContext) -> None:
    """Handle incoming message: call APIM /chat and reply."""
    user_text = _extract_prompt(turn_context.activity)
    if not user_text.strip():
        await turn_context.send_activity("Please send a question.")
        return

    use_case = _infer_use_case(turn_context.activity, user_text)
    logging.info(
        "Received Teams bot message conversation_type=%s recipient=%s use_case=%s text=%s",
        getattr(turn_context.activity.conversation, "conversation_type", ""),
        getattr(turn_context.activity.recipient, "name", ""),
        use_case,
        user_text[:200],
    )

    payload = {"prompt": user_text, "use_case": use_case}
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                APIM_CHAT_URL,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=aiohttp.ClientTimeout(total=60),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    answer = data.get("response", "No response from agent.")
                else:
                    body = await resp.text()
                    answer = f"Error from APIM ({resp.status}): {body[:500]}"
    except Exception as exc:
        logging.exception("APIM call failed for use_case=%s", use_case)
        answer = f"Failed to reach the agent: {exc}"

    await turn_context.send_activity(answer)


async def main(req: func.HttpRequest) -> func.HttpResponse:
    """Bot Framework webhook entry point."""
    if req.method != "POST":
        return func.HttpResponse(status_code=405)

    body = req.get_body().decode("utf-8")
    activity = Activity().deserialize(json.loads(body))
    auth_header = req.headers.get("Authorization", "")

    response = await _adapter.process_activity(activity, auth_header, _on_message)
    if response:
        return func.HttpResponse(
            body=json.dumps(response.body),
            status_code=response.status,
            headers={"Content-Type": "application/json"},
        )
    return func.HttpResponse(status_code=200)
