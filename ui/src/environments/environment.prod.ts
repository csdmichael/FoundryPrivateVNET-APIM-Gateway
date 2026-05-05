// Production API URL — must match config/azure_resources.json → apim.gateway_url + apim.api_path
// Update this value when the APIM gateway or API path changes in the config.
export const environment: { production: boolean; apiUrl: string } = {
  production: true,
  apiUrl: 'https://ai-gateway-apim-poc-my.azure-api.net/foundry-privatevnet-app/api',
};
