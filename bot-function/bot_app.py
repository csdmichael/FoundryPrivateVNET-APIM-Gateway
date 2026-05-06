"""Bot Framework web app — receives Teams messages and proxies to APIM /chat.

Run with: gunicorn --bind=0.0.0.0 --timeout 600 -k aiohttp.GunicornWebWorker bot_app:app
"""

import json
import logging
import os

import aiohttp as aiohttp_client
from aiohttp import web
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

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


async def _on_message(turn_context: TurnContext) -> None:
    user_text = turn_context.activity.text or ""
    if not user_text.strip():
        await turn_context.send_activity("Please send a question.")
        return

    payload = {"prompt": user_text}
    try:
        async with aiohttp_client.ClientSession() as session:
            async with session.post(
                APIM_CHAT_URL,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=aiohttp_client.ClientTimeout(total=60),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    answer = data.get("response", "No response from agent.")
                else:
                    body = await resp.text()
                    answer = f"Error from APIM ({resp.status}): {body[:500]}"
    except Exception as exc:
        logger.exception("APIM call failed")
        answer = f"Failed to reach the agent: {exc}"

    await turn_context.send_activity(answer)


async def messages(req: web.Request) -> web.Response:
    if req.content_type != "application/json":
        return web.Response(status=415)

    body = await req.json()
    activity = Activity().deserialize(body)
    auth_header = req.headers.get("Authorization", "")

    response = await _adapter.process_activity(activity, auth_header, _on_message)
    if response:
        return web.json_response(data=response.body, status=response.status)
    return web.Response(status=200)


async def health(req: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


app = web.Application()
app.router.add_post("/api/messages", messages)
app.router.add_get("/api/health", health)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
