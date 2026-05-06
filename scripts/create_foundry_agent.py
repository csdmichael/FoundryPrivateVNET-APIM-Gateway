"""Create a Foundry agent for the active use case using the local project connection."""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config

from azure.ai.agents import AgentsClient
from azure.ai.agents.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchToolDefinition,
    AzureAISearchToolResource,
    ToolResources,
)
from azure.identity import DefaultAzureCredential


USE_CASE = config.get_use_case()
AGENT_SETTINGS = config.uc_agent_config(USE_CASE)["agent"]
SEARCH_ASSETS = config.use_case_settings(USE_CASE)["search_assets"]
AZURE_RESOURCES = config.azure_resources()

PROJECT_ENDPOINT = config.project_endpoint()
AGENT_NAME = AGENT_SETTINGS["name"]
MODEL_DEPLOYMENT_NAME = os.environ.get("MODEL_DEPLOYMENT_NAME", AGENT_SETTINGS["model_deployment"])
INDEX_NAME = SEARCH_ASSETS["index"]
SEARCH_TOP_K = int(os.environ.get("SEARCH_TOP_K", "15"))
QUERY_TYPE = AzureAISearchQueryType.SEMANTIC
QUERY_TYPE_LABEL = "semantic"


def _resolve_endpoint() -> str:
    """Return the APIM-proxied Foundry agents endpoint when available, else the direct endpoint."""
    if os.environ.get("FOUNDRY_DIRECT", "").strip().lower() in ("1", "true"):
        return PROJECT_ENDPOINT

    apim = AZURE_RESOURCES.get("apim", {})
    agents_path = apim.get("foundry_agents_api_path")
    gateway_url = apim.get("gateway_url", "").rstrip("/")
    if agents_path and gateway_url:
        # APIM proxies to https://{account}.services.ai.azure.com;
        # the SDK path after the gateway URL mirrors the original Foundry path.
        project_suffix = PROJECT_ENDPOINT.split(".services.ai.azure.com", 1)[-1]
        endpoint = f"{gateway_url}/{agents_path}{project_suffix}"
        return endpoint

    return PROJECT_ENDPOINT

_GROUNDING_SUFFIX = (
    "\n\nGROUNDING POLICY: "
    "Always answer strictly from azure_ai_search retrieved chunks. "
    "Never use web search, browser search, or any external source. "
    "Each chunk starts with 'Document: <fileName>' and that fileName must be used for citations. "
    "If relevant chunks are present, provide the best grounded answer and do not return a generic not-found response. "
    "Every factual sentence must include at least one citation in the format [fileName†index-name]."
)
AGENT_INSTRUCTIONS = f"{AGENT_SETTINGS['instructions']}{_GROUNDING_SUFFIX}"


def _connection_id() -> str:
    connection_name = os.environ.get(
        "AZURE_AI_SEARCH_CONNECTION_NAME",
        AZURE_RESOURCES["foundry"]["search_connection_name"],
    ).strip()
    if os.environ.get("AZURE_AI_SEARCH_CONNECTION_ID", "").strip():
        return os.environ["AZURE_AI_SEARCH_CONNECTION_ID"].strip()

    subscription_id = AZURE_RESOURCES["subscription_id"]
    resource_group = AZURE_RESOURCES["resource_group"]
    account_name = AZURE_RESOURCES["foundry"]["account_name"]
    project_name = PROJECT_ENDPOINT.rstrip("/").split("/")[-1]
    return (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{account_name}"
        f"/projects/{project_name}/connections/{connection_name}"
    )


def _tool_type_name(tool) -> str:
    if isinstance(tool, dict):
        return str(tool.get("type", "")).strip().lower()
    return str(getattr(tool, "type", "")).strip().lower()


def _is_search_only_agent(agent) -> bool:
    tools = list(getattr(agent, "tools", None) or [])
    return len(tools) == 1 and _tool_type_name(tools[0]) == "azure_ai_search"


def _get_agent_by_name(client: AgentsClient, agent_name: str):
    for _ in range(3):
        try:
            for agent in client.list_agents():
                if agent.name == agent_name:
                    return agent
            return None
        except Exception:
            time.sleep(1.0)
    return None


def _build_agent(client: AgentsClient, connection_id: str):
    ai_search_index = AISearchIndexResource(
        index_connection_id=connection_id,
        index_name=INDEX_NAME,
        query_type=QUERY_TYPE,
        top_k=SEARCH_TOP_K,
    )
    tool_resources = ToolResources(
        azure_ai_search=AzureAISearchToolResource(index_list=[ai_search_index])
    )
    return client.create_agent(
        model=MODEL_DEPLOYMENT_NAME,
        name=AGENT_NAME,
        instructions=AGENT_INSTRUCTIONS,
        tools=[AzureAISearchToolDefinition()],
        tool_resources=tool_resources,
        temperature=0,
    )


def main() -> None:
    endpoint = _resolve_endpoint()
    is_apim = endpoint != PROJECT_ENDPOINT
    print(f"Connecting to Foundry project: {endpoint}")
    if is_apim:
        print("  (routed via APIM gateway)")
    credential = DefaultAzureCredential()
    client = AgentsClient(endpoint=endpoint, credential=credential)
    connection_id = _connection_id()

    existing = _get_agent_by_name(client, AGENT_NAME)
    if existing and _is_search_only_agent(existing):
        client.delete_agent(existing.id)
        print(f"Deleted existing agent: {existing.id}")
    elif existing:
        client.delete_agent(existing.id)
        print(f"Deleted non-compliant agent: {existing.id}")

    print(f"\nCreating agent: {AGENT_NAME}")
    created = _build_agent(client, connection_id)
    print("\nAgent created successfully!")
    print(f"  Agent ID:     {created.id}")
    print(f"  Agent Name:   {created.name}")
    print(f"  Model:        {created.model}")
    print("  Tool:         azure_ai_search (native)")
    print(f"  Connection:   {connection_id}")
    print(f"  Index:        {INDEX_NAME}")
    print(f"  Query type:   {QUERY_TYPE_LABEL}")
    print(f"  top_k:        {SEARCH_TOP_K}")


if __name__ == "__main__":
    main()