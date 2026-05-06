"""Bot Framework messaging endpoint for Teams agents.

Receives messages from Teams via Bot Framework, calls the APIM /chat endpoint,
and sends the response back to the user.
"""

import json
import logging
import os

import aiohttp
import azure.functions as func
from botbuilder.core import BotFrameworkAdapter, BotFrameworkAdapterSettings, TurnContext
from botbuilder.schema import Activity

APIM_CHAT_URL = os.environ.get(
    "APIM_CHAT_URL",
    "https://ai-gateway-apim-poc-my.azure-api.net/foundry-privatevnet-app/chat",
)
BOT_APP_ID = os.environ.get("MicrosoftAppId", "")
BOT_APP_PASSWORD = os.environ.get("MicrosoftAppPassword", "")

_settings = BotFrameworkAdapterSettings(BOT_APP_ID, BOT_APP_PASSWORD)
_adapter = BotFrameworkAdapter(_settings)


async def _on_message(turn_context: TurnContext) -> None:
    """Handle incoming message: call APIM /chat and reply."""
    user_text = turn_context.activity.text or ""
    if not user_text.strip():
        await turn_context.send_activity("Please send a question.")
        return

    payload = {"prompt": user_text}
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
        logging.exception("APIM call failed")
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
