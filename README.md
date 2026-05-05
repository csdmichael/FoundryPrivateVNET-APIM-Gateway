# Foundry Private VNET APIM Gateway

This repository implements a private Azure AI Foundry deployment where Azure API Management is the AI Gateway and the primary control plane for client-to-agent traffic. The solution uses Terraform for infrastructure, a FastAPI backend behind APIM, and an adapted Ionic/Angular UI deployed with the API on a shared App Service Plan.

## Focus

The main design goal is to place APIM in front of Foundry so gateway concerns are handled centrally:

- expose a single client-facing API surface for the web app and Teams packages
- keep Foundry and Azure AI Search behind private networking and private DNS
- apply APIM import, routing, product, policy, and subscription controls in one place
- let the backend call APIM-managed routes instead of calling Foundry directly

The architecture diagram is in [docs/architecture.png](/c:/Projects/Foundry/FoundryPrivateVNET-APIM-Gateway/docs/architecture.png).

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
- APIM import spec in [openapi/foundry-privatevnet-app.openapi.json](/c:/Projects/Foundry/FoundryPrivateVNET-APIM-Gateway/openapi/foundry-privatevnet-app.openapi.json)
- PowerShell automation for deployment, APIM configuration, Search asset cloning, Foundry agent cloning, Teams packaging, and prompt smoke tests
- Teams packages for the two retained agents
- best-practices guidance in [docs/best-practices.md](/c:/Projects/Foundry/FoundryPrivateVNET-APIM-Gateway/docs/best-practices.md)

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

That script runs Terraform init, validate, plan, and apply, then executes Search cloning, Foundry agent cloning, APIM configuration, Teams package generation, and sample prompt tests.

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

Before publishing to Teams, replace manifest placeholders so the package points at your APIM hostname and keep `validDomains` aligned to that gateway host.

## Testing

Run sample prompts against a deployed API:

```powershell
$env:APP_API_BASE_URL = "https://<your-api-host>/api"
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

Validate region, SKU, and existing resource assumptions in [main.tfvars.json](/c:/Projects/Foundry/FoundryPrivateVNET-APIM-Gateway/main.tfvars.json) before running apply in a different subscription or environment.
