"""Create (or update) a Foundry agent that calls the private Data Function API as an OpenAPI tool.

All values come from config/function_app_config.json and config/azure_resources.json.
The agent reaches the Function App only through the private APIM gateway; the Foundry
project resolves APIM via its private endpoint, so no traffic leaves the VNet.

Auth model (best practice): the APIM data-function API is protected with Entra ID token
validation (validate-azure-ad-token). The OpenAPI tool authenticates with the Foundry
project's **managed identity**, which requests a token for the audience configured in
config/function_app_config.json -> apim.entra_auth.audience. APIM validates the token's
audience, tenant, and object id before forwarding to the private Function backend. This
replaces fragile IP allowlisting for the agent's egress path. If apim.entra_auth.enabled
is false, the tool falls back to anonymous auth (dev-IP allowlist only).

Uses the nextgen Azure AI Foundry SDK (azure-ai-projects AIProjectClient).

Usage:
    python scripts/create_function_agent.py
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config

from azure.ai.projects import AIProjectClient
from azure.ai.agents.models import (
    OpenApiAnonymousAuthDetails,
    OpenApiManagedAuthDetails,
    OpenApiManagedSecurityScheme,
    OpenApiTool,
)
from azure.identity import DefaultAzureCredential

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FUNC_CFG = config.function_app_config()
RES = config.azure_resources()

PROJECT_ENDPOINT = config.project_endpoint()
AGENT_CFG = FUNC_CFG["foundry_agent"]
AGENT_NAME = AGENT_CFG["name"]
MODEL_DEPLOYMENT = os.environ.get("MODEL_DEPLOYMENT_NAME", AGENT_CFG["model_deployment"])
TOOL_NAME = AGENT_CFG["tool_name"]
APIM_CFG = FUNC_CFG["apim"]
ENTRA_AUTH = APIM_CFG.get("entra_auth", {})

# Server URL the agent calls = APIM gateway + API path (config-driven, no hardcode).
GATEWAY = RES["apim"]["gateway_url"].rstrip("/")
API_PATH = APIM_CFG["api_path"].strip("/")
APIM_SERVER_URL = f"{GATEWAY}/{API_PATH}"


def _load_openapi_spec() -> dict:
    spec_path = os.path.join(PROJECT_ROOT, "function-app", "openapi.json")
    with open(spec_path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    # Point the tool at the private APIM gateway path.
    spec["servers"] = [{"url": APIM_SERVER_URL, "description": "Private APIM AI gateway"}]
    return spec


def _build_auth():
    """Managed-identity auth when entra_auth is enabled, else anonymous (dev IP allowlist)."""
    if ENTRA_AUTH.get("enabled"):
        audience = ENTRA_AUTH["audience"]
        print(f"Auth: managed identity (audience={audience})")
        return OpenApiManagedAuthDetails(
            security_scheme=OpenApiManagedSecurityScheme(audience=audience)
        )
    print("Auth: anonymous (APIM dev-IP allowlist)")
    return OpenApiAnonymousAuthDetails()


def main() -> None:
    spec = _load_openapi_spec()
    openapi_tool = OpenApiTool(
        name=TOOL_NAME,
        spec=spec,
        description=APIM_CFG["api_description"],
        auth=_build_auth(),
    )

    project = AIProjectClient(
        endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential()
    )

    with project:
        agents = project.agents
        existing = next((a for a in agents.list_agents() if a.name == AGENT_NAME), None)
        if existing:
            agent = agents.update_agent(
                agent_id=existing.id,
                model=MODEL_DEPLOYMENT,
                name=AGENT_NAME,
                instructions=AGENT_CFG["instructions"],
                tools=openapi_tool.definitions,
            )
            print(f"Updated agent '{AGENT_NAME}' (id={agent.id})")
        else:
            agent = agents.create_agent(
                model=MODEL_DEPLOYMENT,
                name=AGENT_NAME,
                instructions=AGENT_CFG["instructions"],
                tools=openapi_tool.definitions,
            )
            print(f"Created agent '{AGENT_NAME}' (id={agent.id})")

    print(f"Tool '{TOOL_NAME}' -> {APIM_SERVER_URL}")
    print(f"Project endpoint    : {PROJECT_ENDPOINT}")
    print("Open the agent in Azure AI Foundry: https://ai.azure.com")


if __name__ == "__main__":
    main()
