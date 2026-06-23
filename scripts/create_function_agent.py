"""Create (or update) a Foundry agent that calls the private Data Function API as an OpenAPI tool.

All values come from config/function_app_config.json and config/azure_resources.json.
The agent reaches the Function App only through the private APIM gateway; the Foundry
project resolves APIM via its private endpoint, so no traffic leaves the VNet.

Auth model: the APIM API is imported with subscription_required=false and is only
reachable inside the VNet, so the OpenAPI tool uses anonymous auth. To require a
subscription key instead, set a key connection and switch to OpenApiConnectionAuthDetails.

Usage:
    python scripts/create_function_agent.py
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import OpenApiAnonymousAuthDetails, OpenApiTool
from azure.identity import DefaultAzureCredential

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FUNC_CFG = config.function_app_config()
RES = config.azure_resources()

PROJECT_ENDPOINT = config.project_endpoint()
AGENT_CFG = FUNC_CFG["foundry_agent"]
AGENT_NAME = AGENT_CFG["name"]
MODEL_DEPLOYMENT = os.environ.get("MODEL_DEPLOYMENT_NAME", AGENT_CFG["model_deployment"])
TOOL_NAME = AGENT_CFG["tool_name"]

# Server URL the agent calls = APIM gateway + API path (config-driven, no hardcode).
GATEWAY = RES["apim"]["gateway_url"].rstrip("/")
API_PATH = FUNC_CFG["apim"]["api_path"].strip("/")
APIM_SERVER_URL = f"{GATEWAY}/{API_PATH}"


def _load_openapi_spec() -> dict:
    spec_path = os.path.join(PROJECT_ROOT, "function-app", "openapi.json")
    with open(spec_path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    # Point the tool at the private APIM gateway path.
    spec["servers"] = [{"url": APIM_SERVER_URL, "description": "Private APIM AI gateway"}]
    return spec


def main() -> None:
    spec = _load_openapi_spec()
    auth = OpenApiAnonymousAuthDetails()
    openapi_tool = OpenApiTool(
        name=TOOL_NAME,
        spec=spec,
        description=FUNC_CFG["apim"]["api_description"],
        auth=auth,
    )

    client = AgentsClient(endpoint=PROJECT_ENDPOINT, credential=DefaultAzureCredential())

    with client:
        existing = next((a for a in client.list_agents() if a.name == AGENT_NAME), None)
        if existing:
            agent = client.update_agent(
                agent_id=existing.id,
                model=MODEL_DEPLOYMENT,
                name=AGENT_NAME,
                instructions=AGENT_CFG["instructions"],
                tools=openapi_tool.definitions,
            )
            print(f"Updated agent '{AGENT_NAME}' (id={agent.id})")
        else:
            agent = client.create_agent(
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
