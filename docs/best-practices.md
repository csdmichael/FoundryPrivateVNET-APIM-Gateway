# Best Practices for Foundry Private Networking and APIM AI Gateway

## Private networking

- Use private endpoints for Azure AI Foundry and Azure AI Search so the data plane stays inside your private address space.
- Link the required private DNS zones to the application VNet so name resolution stays consistent for App Service VNet integration.
- Use a dedicated subnet for private endpoints and a separate delegated subnet for App Service VNet integration.
- Keep `publicNetworkAccess` disabled on resources after private connectivity is verified.

Microsoft Learn references:

- https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link
- https://learn.microsoft.com/azure/ai-services/agents/how-to/virtual-networks
- https://learn.microsoft.com/azure/ai-foundry/how-to/configure-managed-network

## API Management as AI gateway

- Put APIM in front of Foundry agent endpoints so the UI and backend consume one stable gateway surface.
- Use APIM products and subscriptions to control consumer access rather than embedding Foundry credentials in the app.
- Apply APIM policies for backend routing, request logging, and future token governance.
- Import explicit OpenAPI definitions for the UI-facing backend API so APIM ownership is declarative.

Microsoft Learn references:

- https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
- https://learn.microsoft.com/azure/api-management/import-and-publish
- https://learn.microsoft.com/azure/api-management/backends

## App Service deployment

- Keep UI and API on a shared Linux plan only when the scaling profile is aligned; split plans later if the UI and API diverge operationally.
- Use user-assigned managed identities from day one so downstream access can move to RBAC instead of secrets.
- Send App Service diagnostics to Log Analytics and keep health probes enabled on the API.

Microsoft Learn references:

- https://learn.microsoft.com/azure/app-service/configure-vnet-integration-enable
- https://learn.microsoft.com/azure/app-service/overview-vnet-integration
- https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings
