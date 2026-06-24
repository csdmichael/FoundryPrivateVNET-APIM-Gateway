"""Create (or update) the Data-Function-Agent on the network-injection Foundry project.

Unlike the APIM edition, this agent calls the private Data Function App **directly** over
private networking. The Foundry account uses virtual network injection, so the agent compute
runs inside the eastus2 VNet and resolves the Function App's private endpoint through private
DNS. The OpenAPI tool's server URL is the PRIVATE function host + route prefix, and auth is
anonymous — the private network boundary (disabled public access + private endpoint) is the
access control. No APIM gateway and no Entra token are involved.

All values come from config/network_injection_config.json (no hardcoding).

Uses the nextgen Azure AI Foundry SDK (azure-ai-projects AIProjectClient).

IMPORTANT: this script must run from a host that can reach the private Foundry project
endpoint (i.e. inside the injected VNet, or while the account is temporarily IP-allowed via
scripts/enable-portal-access.ps1 -Mode IpAllow). From the public internet against a fully
private account it will fail to connect.

Usage:
    python scripts/create_ni_function_agent.py
"""

import json
import os
import sys

CONFIG_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "config",
    "network_injection_config.json",
)
OPENAPI_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "function-app",
    "openapi.json",
)

from azure.ai.projects import AIProjectClient
from azure.ai.agents.models import OpenApiAnonymousAuthDetails, OpenApiTool
from azure.identity import DefaultAzureCredential


def _load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _load_openapi_spec(server_url: str) -> dict:
    with open(OPENAPI_PATH, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    # Point the tool DIRECTLY at the private Function App host (resolved via private DNS
    # from inside the injected subnet). No APIM hop.
    spec["servers"] = [{"url": server_url, "description": "Private Function App (network injection)"}]
    return spec


def main() -> None:
    cfg = _load_config()
    agent_cfg = cfg["foundry_agent"]
    project_endpoint = cfg["foundry"]["project_endpoint"]
    agent_name = agent_cfg["name"]
    model = os.environ.get("MODEL_DEPLOYMENT_NAME", agent_cfg["model_deployment"])
    tool_name = agent_cfg["tool_name"]
    # Direct private Function App host ROOT. The OpenAPI spec's paths already include the
    # '/api' route prefix (e.g. '/api/categories'), so the tool server must be the bare host
    # (no '/api'); otherwise the calls double up to '/api/api/...' and 404.
    server_url = cfg["endpoints"]["function_default_hostname"]

    spec = _load_openapi_spec(server_url)
    openapi_tool = OpenApiTool(
        name=tool_name,
        spec=spec,
        description="Private Azure Function data APIs (catalog, inventory, orders) reached "
        "directly over the injected VNet.",
        auth=OpenApiAnonymousAuthDetails(),
    )
    print(f"Auth: anonymous (private network boundary). Tool server: {server_url}")

    project = AIProjectClient(endpoint=project_endpoint, credential=DefaultAzureCredential())
    with project:
        agents = project.agents
        existing = next((a for a in agents.list_agents() if a.name == agent_name), None)
        if existing:
            agent = agents.update_agent(
                agent_id=existing.id,
                model=model,
                name=agent_name,
                instructions=agent_cfg["instructions"],
                tools=openapi_tool.definitions,
            )
            print(f"Updated agent '{agent_name}' (id={agent.id})")
        else:
            agent = agents.create_agent(
                model=model,
                name=agent_name,
                instructions=agent_cfg["instructions"],
                tools=openapi_tool.definitions,
            )
            print(f"Created agent '{agent_name}' (id={agent.id})")

    print(f"Tool '{tool_name}' -> {server_url}")
    print(f"Project endpoint   : {project_endpoint}")
    print("Open the agent in Azure AI Foundry: https://ai.azure.com")


if __name__ == "__main__":
    main()
