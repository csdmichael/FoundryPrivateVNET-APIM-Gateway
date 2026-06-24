"""Invoke the Data-Function-Agent end-to-end to prove the network-injection path works.

This is the functional retest for the network-injection edition: it asks the agent a
question that can ONLY be answered by calling the private Data Function App through its
OpenAPI tool. Because the Foundry account uses virtual network injection, the agent compute
runs inside the eastus2 VNet and resolves the Function App's private endpoint over private
DNS. The Function App now has publicNetworkAccess=Disabled, so a successful tool call proves
the private path (agent subnet -> private DNS -> private endpoint) is intact.

All values come from config/network_injection_config.json (no hardcoding).

IMPORTANT: like create_ni_function_agent.py, this must run from a host that can reach the
private Foundry project endpoint (inside the injected VNet, or while the account is
temporarily IP-allowed via scripts/enable-portal-access.ps1 -Mode IpAllow). The agent->function
call itself always happens privately inside the VNet regardless of where this script runs.

Usage:
    python scripts/test_ni_function_agent.py
    python scripts/test_ni_function_agent.py "How many products are in the Electronics category?"
"""

import json
import os
import sys
import time

CONFIG_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "config",
    "network_injection_config.json",
)

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

DEFAULT_PROMPT = (
    "List the available product categories, then tell me how many products are in stock "
    "in the first category. Use the data_function_api tool."
)


def _load_config() -> dict:
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        return json.load(fh)


def main() -> None:
    cfg = _load_config()
    agent_name = cfg["foundry_agent"]["name"]
    project_endpoint = cfg["foundry"]["project_endpoint"]
    prompt = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PROMPT

    project = AIProjectClient(endpoint=project_endpoint, credential=DefaultAzureCredential())
    with project:
        agents = project.agents
        agent = next((a for a in agents.list_agents() if a.name == agent_name), None)
        if agent is None:
            print(f"ERROR: agent '{agent_name}' not found. Run create_ni_function_agent.py first.")
            sys.exit(1)
        print(f"Agent       : {agent_name} (id={agent.id})")
        print(f"Project     : {project_endpoint}")
        print(f"Prompt      : {prompt}\n")

        thread = agents.threads.create()
        agents.messages.create(thread_id=thread.id, role="user", content=prompt)

        run = agents.runs.create(thread_id=thread.id, agent_id=agent.id)
        print(f"Run started : {run.id} (thread={thread.id})")

        # Poll to completion.
        terminal = {"completed", "failed", "cancelled", "expired"}
        while run.status not in terminal:
            time.sleep(2)
            run = agents.runs.get(thread_id=thread.id, run_id=run.id)
            print(f"  status: {run.status}")

        print(f"\nRun status  : {run.status}")
        if run.status == "failed":
            print(f"Last error  : {getattr(run, 'last_error', None)}")
            sys.exit(2)

        # Print the assistant's final answer.
        print("\n=== Agent response ===")
        for msg in agents.messages.list(thread_id=thread.id):
            if msg.role == "assistant":
                for part in msg.content:
                    text = getattr(getattr(part, "text", None), "value", None)
                    if text:
                        print(text)
                break

    print("\n==> Retest complete. A non-empty, data-bearing answer above confirms the agent "
          "reached the PRIVATE Function App over the injected VNet.")


if __name__ == "__main__":
    main()
