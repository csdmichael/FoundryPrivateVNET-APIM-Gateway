# Foundry Private VNET APIM Gateway

This repository implements a private Azure AI Foundry deployment where Azure API Management is the AI Gateway and the primary control plane for client-to-agent traffic. The solution uses Terraform for infrastructure, a FastAPI backend behind APIM, and an adapted Ionic/Angular UI deployed with the API on a shared App Service Plan.

## Focus

The main design goal is to place APIM in front of Foundry so gateway concerns are handled centrally:

- expose a single client-facing API surface for the web app and Teams packages
- keep Foundry and Azure AI Search behind private networking and private DNS
- apply APIM import, routing, product, policy, and subscription controls in one place
- let the backend call APIM-managed routes instead of calling Foundry directly

![Architecture](docs/architecture.png)

## Live URLs

| Service | URL |
|---------|-----|
| UI | https://foundry-privatevnet-ui.azurewebsites.net |
| API | https://foundry-privatevnet-api.azurewebsites.net/api |
| API Health | https://foundry-privatevnet-api.azurewebsites.net/api/health |
| APIM Gateway | https://apim-poc-my.azure-api.net |
| APIM API Surface | https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api |

## Solution Overview

The deployed topology is:

- Azure AI Foundry project with private endpoint access
- Azure AI Search with private endpoint access
- Azure API Management as the public gateway and policy boundary
- one Linux App Service Plan hosting the UI App Service and API App Service
- VNet integration for the apps through a delegated subnet
- Log Analytics and diagnostic settings for the web apps

## Included Assets

- Terraform for VNet, subnets, private endpoints, private DNS, shared App Service Plan, App Services, identities, and diagnostics
- APIM import spec in [openapi/foundry-privatevnet-app.openapi.json](openapi/foundry-privatevnet-app.openapi.json)
- PowerShell automation for deployment, APIM configuration, source-driven private Search and agent provisioning, Teams packaging, and prompt smoke tests
- Teams packages for the two retained agents
- best-practices guidance in [docs/best-practices.md](docs/best-practices.md)

## Use Cases

The repo retains only the two Cosmos DB-backed use cases, and they are intentionally brief here because the repo focus is the APIM-to-Foundry gateway pattern rather than the business domain payloads.

- Tax PDF Forms: a Cosmos DB-backed corpus of PDF tax form content exposed through Azure AI Search and served by `Tax-PDF-Forms-Agent`
- Engineering Design PPT: a Cosmos DB-backed corpus of presentation content exposed through Azure AI Search and served by `Eng-Design-PPT-Agent`

The previous non-Cosmos use cases were removed from the active documentation surface.

## Deployment

Local prerequisites:

- Terraform 1.6+
- Azure CLI
- Docker
- Node.js 20+
- Python 3.11+

Main workflow:

```powershell
./scripts/deploy.ps1
```

That script runs Terraform validate plus a direct apply by default, then provisions the retained Search indexes and Foundry agents from the source-controlled definitions in `csdmichael/AI-Search-Blob-Storage`, configures APIM, generates Teams packages, and runs sample prompt tests.

For faster iterative deployments, skip steps you are not changing:

```powershell
./scripts/deploy.ps1 -SkipTests -SkipPackage
```

If you want the slower two-step Terraform flow with a saved plan file, use:

```powershell
./scripts/deploy.ps1 -DetailedPlan
```

## GitHub Actions Setup

The GitHub Actions deployment path is already wired for OpenID Connect with a user-assigned managed identity, so no client secret is required.

Provisioned Azure identity:

- identity name: `gha-foundry-privatevnet-oidc`
- client id: `b01a1a97-faef-4d58-8a9a-764d0b2697ec`
- tenant id: `b158173c-91f6-4f99-b5e9-aa9bcb463863`
- subscription id: `86b37969-9445-49cf-b03f-d8866235171c`

Federated credentials configured on that identity:

- `repo:csdmichael/FoundryPrivateVNET-APIM-Gateway:ref:refs/heads/main`

Azure RBAC granted to that identity:

- `Contributor` on resource group `ai-myaacoub`
- `Azure AI Developer` on `foundryprivatevnet`
- `Azure AI Developer` on `001-ai-poc`
- `Search Service Contributor` on `aisearch-poc-myaacoub`

Repository secrets configured in `csdmichael/FoundryPrivateVNET-APIM-Gateway`:

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | `b01a1a97-faef-4d58-8a9a-764d0b2697ec` |
| `AZURE_TENANT_ID` | `b158173c-91f6-4f99-b5e9-aa9bcb463863` |
| `AZURE_SUBSCRIPTION_ID` | `86b37969-9445-49cf-b03f-d8866235171c` |
| `API_WEBAPP_NAME` | `foundry-privatevnet-api` |
| `UI_WEBAPP_NAME` | `foundry-privatevnet-ui` |
| `APP_API_BASE_URL` | `https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api` |

GitHub environments are not required by the current workflow. The deployment runs as a single pipeline against one Terraform configuration and authenticates through the `main` branch OIDC subject.

When you run the `deploy` workflow manually from GitHub Actions, `deploy_api` and `deploy_ui` inputs let you skip either app deployment. Pushes to `main` still deploy both by default.

Recommended operator flow:

1. Push to `main` or run the `deploy` workflow manually from GitHub Actions.
2. Let the `terraform` job finish before checking the app deployments.
3. Validate `https://foundry-privatevnet-api.azurewebsites.net/api/health`.
4. Validate `https://foundry-privatevnet-ui.azurewebsites.net`.
5. Validate the APIM gateway path `https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api`.

Notes:

- The workflow uses a single Terraform configuration and a branch-scoped OIDC credential for `main`.
- The UI deployment job publishes the Angular build output from `ui/www`, and the App Service is configured to serve that static bundle through `pm2`.
- The sample prompt smoke test runs through APIM, not directly against the backend App Service.
- Post-deploy provisioning now clones `https://github.com/csdmichael/AI-Search-Blob-Storage` at runtime and overlays this repo's private Foundry, Search, and Cosmos resource settings.
- The private Foundry project uses the `aisearchpocmyaacoub` Azure AI Search connection created by `scripts/ensure-foundry-search-connection.ps1`.
- The private Search service must have a system-assigned managed identity enabled.
- That Search managed identity must have Cosmos DB account reader plus Cosmos SQL data access on `cosmos-ai-poc`.
- The private Search service must have an approved shared private link to `cosmos-ai-poc` named `cosmos-ai-poc-sql` before Cosmos-backed Search indexers can populate data.

## APIM Configuration

The backend OpenAPI surface is imported into APIM and then bound to the deployed API backend.

```powershell
./scripts/configure-apim.ps1
```

The production UI is configured to call:

- `https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api`

Backend settings used by the App Service deployment:

- `APIM_GATEWAY_URL`
- `APIM_SUBSCRIPTION_KEY`
- `ALLOWED_ORIGINS`
- `TAX_PDF_FORMS_APIM_PATH`
- `ENG_DESIGN_PPT_APIM_PATH`

## Teams Packages

Teams package generation:

```powershell
./scripts/package-teams-agents.ps1
```

Generated packages:

- `Agent-Packages/Tax-PDF-Forms-Agent/Tax-PDF-Forms-Agent.zip`
- `Agent-Packages/Eng-Design-PPT-Agent/Eng-Design-PPT-Agent.zip`

## Source-Driven Search And Agent Provisioning

The deployment no longer clones live Azure Search objects or live Foundry agents from the source environment.

Instead, the post-deploy step clones `https://github.com/csdmichael/AI-Search-Blob-Storage`, overlays the private target resource settings from this repo, and provisions only the retained use cases:

- `tax_pdf_forms`
- `eng_design_ppt`

The provisioning wrapper is:

```powershell
./scripts/provision-source-use-cases.ps1
```

Compatibility entrypoints still exist:

```powershell
./scripts/clone-search-assets.ps1
./scripts/clone-foundry-agents.ps1
```

Those wrappers now delegate to the source-driven provisioning flow instead of cloning live Azure objects.

Important network prerequisite:

- `aisearch-poc-myaacoub` must be able to reach `cosmos-ai-poc` through an approved Search shared private link resource named `cosmos-ai-poc-sql`.

Before publishing to Teams, replace manifest placeholders so the package points at your APIM hostname and keep `validDomains` aligned to that gateway host.

## Demo Script

Use this sequence for a live walkthrough after the GitHub Actions deployment completes:

1. Open the UI at `https://foundry-privatevnet-ui.azurewebsites.net` and show the two retained use cases.
2. Open the API health endpoint at `https://foundry-privatevnet-api.azurewebsites.net/api/health`.
3. Open the APIM surface at `https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api/health` to show the gateway hop.
4. Run the packaged smoke tests:

```powershell
$env:APP_API_BASE_URL = "https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api"
./scripts/test-sample-prompts.ps1
```

5. Use prompts from [Prompts.txt](Prompts.txt) to demo both retained agents.
6. Show the generated Teams packages under `Agent-Packages/`.

## Packaging Agents For Teams And Other Clients

This repo keeps APIM as the only public ingress. Keep that pattern when you publish the agents to Teams or any other client shell.

Best practices:

- Route every client-facing manifest, shortcut, or launcher to APIM, not directly to Foundry or the backend App Service.
- Keep `validDomains`, privacy URLs, terms URLs, and any web endpoint metadata aligned to the APIM hostname.
- Keep agent-specific routes stable in APIM and version them there instead of hardcoding backend URLs into client packages.
- Repackage the client manifests after each APIM hostname or path change.
- Prefer one package per user-facing agent so permissions, icons, names, and rollout can be managed independently.

Teams packaging steps:

1. Update the manifest in `Agent-Packages/<AgentName>/manifest.json`.
2. Keep `developer.websiteUrl`, `developer.privacyUrl`, `developer.termsOfUseUrl`, and `validDomains` set to `https://apim-poc-my.azure-api.net`.
3. If you add bot, tab, message extension, or Copilot endpoints later, point those URLs to the APIM route for that agent rather than to `azurewebsites.net`.
4. Rebuild the package with:

```powershell
./scripts/package-teams-agents.ps1
```

5. Upload the resulting zip from `Agent-Packages/<AgentName>/<AgentName>.zip` into Teams admin center, the Teams developer portal, or your target distribution workflow.

Adapting the same agent for other platforms:

1. Keep the manifest or app configuration client-specific, but keep the backend route APIM-specific.
2. Expose only the APIM route that corresponds to the intended agent, for example `https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api` plus the agent path managed by APIM.
3. Mirror the same hostname allowlist policy used in Teams packages.
4. Treat APIM as the place for auth, policy, throttling, subscriptions, and backend rewrites so each client package stays thin.

## Testing

Run sample prompts against a deployed API:

```powershell
$env:APP_API_BASE_URL = "https://apim-poc-my.azure-api.net/foundry-privatevnet-app/api"
./scripts/test-sample-prompts.ps1
```

## Terraform Notes

The Terraform implementation follows the agreed constraints:

- Terraform is used 
- shared Linux App Service Plan for UI and API
- user-assigned identities on both apps
- private endpoints and private DNS for Foundry and Search
- diagnostics routed to Log Analytics
- existing APIM, Foundry, and Search resources are referenced and configured rather than re-created wholesale

Validate region, SKU, and existing resource assumptions in [main.tfvars.json](main.tfvars.json) before running apply in a different subscription or environment.
