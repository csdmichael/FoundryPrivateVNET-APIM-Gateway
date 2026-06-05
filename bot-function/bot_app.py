"""Bot Framework web app — receives Teams/Direct Line messages and proxies to APIM /chat.

Run with: gunicorn --bind=0.0.0.0 --timeout 600 -k aiohttp.GunicornWebWorker bot_app:app

Design notes:
- Uses CloudAdapter + ConfigurationBotFrameworkAuthentication (botbuilder >= 4.17),
  which natively supports SingleTenant bots (validates inbound JWT against
  https://login.microsoftonline.com/{tenant}/v2.0/.well-known/openid-configuration
  instead of the legacy login.botframework.com endpoint that botbuilder 4.16.x used).
- /api/messages ACKs the channel within milliseconds with a typing indicator,
  then runs the (potentially slow) APIM call in a background asyncio task and
  delivers the reply proactively via adapter.continue_conversation(). This
  prevents Teams/Direct Line from timing out the activity (~15s ceiling) when
  the agent takes longer to respond.
- Any unhandled exception in the adapter pipeline is caught, logged with a
  full traceback, and returned as a JSON 500 body (instead of the bare empty
  500 that aiohttp produces by default), so failures are diagnosable from
  the App Service log stream / Application Logs.
"""

import asyncio
import logging
import os
import re
import sys
from pathlib import Path

import aiohttp as aiohttp_client
from aiohttp import web
from botbuilder.core import TurnContext
from botbuilder.integration.aiohttp import (
    CloudAdapter,
    ConfigurationBotFrameworkAuthentication,
)
from botbuilder.schema import Activity, ActivityTypes, ConversationReference

# Support both local dev (config/ is one level up) and deployed (config/ alongside bot_app.py)
_bot_dir = Path(__file__).resolve().parent
for _candidate in [_bot_dir, _bot_dir.parent]:
    if (_candidate / "config" / "__init__.py").is_file() and str(_candidate) not in sys.path:
        sys.path.insert(0, str(_candidate))
        break

try:
    import config as _project_config
except Exception:
    _project_config = None

VALID_USE_CASES = ("tax_pdf_forms", "eng_design_ppt")
DEFAULT_USE_CASE = "tax_pdf_forms"
APIM_CHAT_URL = os.environ.get("APIM_CHAT_URL")

if _project_config is not None:
    VALID_USE_CASES = tuple(getattr(_project_config, "VALID_USE_CASES", VALID_USE_CASES))
    DEFAULT_USE_CASE = getattr(_project_config, "DEFAULT_USE_CASE", DEFAULT_USE_CASE)
    if not APIM_CHAT_URL:
        APIM_CHAT_URL = _project_config.apim_chat_url()

if not APIM_CHAT_URL:
    APIM_CHAT_URL = "https://ai-gateway-apim-poc-my.azure-api.net/foundry-privatevnet-app/chat"


class _BotConfig:
    """Configuration shim consumed by ConfigurationBotFrameworkAuthentication.

    The SDK reads MicrosoftAppId/Password/Type/TenantId attributes (or the
    APP_ID/APP_PASSWORD/APP_TYPE/APP_TENANTID variants) off this object.
    """

    APP_ID = os.environ.get("MicrosoftAppId", "")
    APP_PASSWORD = os.environ.get("MicrosoftAppPassword", "")
    APP_TYPE = os.environ.get("MicrosoftAppType", "MultiTenant")
    APP_TENANTID = os.environ.get("MicrosoftAppTenantId", "")

    # Aliases for SDK variants that look up the legacy names.
    MicrosoftAppId = APP_ID
    MicrosoftAppPassword = APP_PASSWORD
    MicrosoftAppType = APP_TYPE
    MicrosoftAppTenantId = APP_TENANTID


CONFIG = _BotConfig()
_auth = ConfigurationBotFrameworkAuthentication(CONFIG)
_adapter = CloudAdapter(_auth)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("bot_app")
logger.info(
    "Bot starting: app_id=%s app_type=%s tenant=%s apim=%s",
    _BotConfig.APP_ID,
    _BotConfig.APP_TYPE,
    _BotConfig.APP_TENANTID,
    APIM_CHAT_URL,
)


async def _on_turn_error(context: TurnContext, error: Exception) -> None:
    """CloudAdapter calls this for any unhandled exception inside the turn."""

    logger.exception("Unhandled bot turn error: %s", error)
    try:
        await context.send_activity(
            "Sorry, I hit an unexpected error processing that message."
        )
    except Exception:
        logger.exception("Failed to send error-notification activity to user")


_adapter.on_turn_error = _on_turn_error


# Background tasks must be referenced somewhere or asyncio may GC them mid-flight.
_background_tasks: set[asyncio.Task] = set()


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
    if configured_use_case in VALID_USE_CASES:
        return configured_use_case

    if _project_config is None:
        prompt_l = prompt.lower()
        if any(token in prompt_l for token in ["engineering", "architecture", "ppt", "design"]):
            return "eng_design_ppt"
        return DEFAULT_USE_CASE

    haystacks = {
        use_case: " ".join(
            [entry["text"] for entry in _project_config.prompts_config()["use_cases"][use_case]["agent"]]
            + [doc["title"] for doc in _project_config.document_config()["use_cases"][use_case]["sample_documents"]]
            + [doc["filename"] for doc in _project_config.document_config()["use_cases"][use_case]["sample_documents"]]
        )
        for use_case in VALID_USE_CASES
    }

    prompt_words = _normalize_words(prompt)
    if not prompt_words:
        return DEFAULT_USE_CASE

    best_use_case = DEFAULT_USE_CASE
    best_score = -1
    for use_case, haystack in haystacks.items():
        score = len(prompt_words & _normalize_words(haystack))
        if score > best_score:
            best_use_case = use_case
            best_score = score

    return best_use_case


async def _call_apim(prompt: str, use_case: str) -> str:
    payload = {"prompt": prompt, "use_case": use_case}
    try:
        async with aiohttp_client.ClientSession() as session:
            async with session.post(
                APIM_CHAT_URL,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=aiohttp_client.ClientTimeout(total=120),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return data.get("response") or "No response from agent."
                body = await resp.text()
                logger.error(
                    "APIM returned %s for use_case=%s: %s",
                    resp.status,
                    use_case,
                    body[:500],
                )
                return f"Agent error ({resp.status}): {body[:500]}"
    except Exception as exc:
        logger.exception("APIM call failed for use_case=%s", use_case)
        return f"Failed to reach the agent: {exc}"


async def _deliver_reply(reference: ConversationReference, prompt: str, use_case: str) -> None:
    """Background worker: call APIM, then send the answer proactively."""

    answer = await _call_apim(prompt, use_case)

    async def _send(ctx: TurnContext) -> None:
        await ctx.send_activity(answer)

    try:
        await _adapter.continue_conversation(
            reference,
            _send,
            bot_app_id=_BotConfig.APP_ID,
        )
    except Exception:
        logger.exception("Failed to deliver proactive reply for use_case=%s", use_case)


async def _on_turn(turn_context: TurnContext) -> None:
    activity = turn_context.activity
    if activity.type != ActivityTypes.message:
        # Ignore conversationUpdate, typing, event, etc.
        return

    user_text = _extract_prompt(activity)
    if not user_text:
        await turn_context.send_activity("Please send a question.")
        return

    use_case = _infer_use_case(activity, user_text)
    logger.info(
        "Bot turn use_case=%s channel=%s conv_type=%s text=%r",
        use_case,
        getattr(activity, "channel_id", ""),
        getattr(activity.conversation, "conversation_type", "") if activity.conversation else "",
        user_text[:200],
    )

    # ACK the channel quickly with a typing indicator so it doesn't time out
    # while APIM (which can take 10-40s) is running.
    try:
        await turn_context.send_activity(Activity(type=ActivityTypes.typing))
    except Exception:
        logger.exception("Failed to send typing indicator")

    # Capture a conversation reference and dispatch the slow work to a
    # background task. The handler returns immediately so /api/messages
    # responds within milliseconds.
    reference = TurnContext.get_conversation_reference(activity)
    task = asyncio.create_task(_deliver_reply(reference, user_text, use_case))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def messages(req: web.Request) -> web.Response:
    try:
        return await _adapter.process(req, _on_turn)
    except Exception as exc:
        logger.exception("Unhandled exception in /api/messages")
        return web.json_response(
            {"error": str(exc), "type": type(exc).__name__},
            status=500,
        )


async def health(req: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


app = web.Application()
app.router.add_post("/api/messages", messages)
app.router.add_get("/api/health", health)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
