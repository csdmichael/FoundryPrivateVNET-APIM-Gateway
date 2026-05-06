terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.2.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    azurecaf = {
      source  = "aztfmod/azurecaf"
      version = ">= 1.2.28"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread = true
}

provider "azapi" {
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "foundry_account_resource_id" {
  type = string
}

variable "foundry_account_name" {
  type = string
}

variable "search_service_name" {
  type = string
}

variable "api_management_name" {
  type = string
}

variable "existing_app_service_plan_name" {
  type    = string
  default = null
}

variable "app_service_plan_sku" {
  type    = string
  default = "P1v3"
}

variable "api_web_app_name" {
  type    = string
  default = null
}

variable "ui_web_app_name" {
  type    = string
  default = null
}

variable "deploy_api" {
  type    = bool
  default = false
}

variable "deploy_ui" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {
    workload = "foundry-privatevnet-apim-gateway"
    managedBy = "terraform"
  }
}

variable "bot_app_id" {
  type        = string
  description = "Entra app registration ID for the Teams bot"
  default     = "37a8fd15-4b3c-4289-9e8c-19b65120b844"
}

variable "bot_app_password" {
  type        = string
  sensitive   = true
  description = "Entra app secret for the Teams bot"
  default     = ""
}

variable "bot_service_plan_name" {
  type        = string
  description = "Existing App Service Plan to host the bot web app"
  default     = "plan-taxforms"
}

data "azurerm_resource_group" "target" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

data "azurerm_api_management" "apim" {
  name                = var.api_management_name
  resource_group_name = data.azurerm_resource_group.target.name
}

data "azurerm_search_service" "target" {
  name                = var.search_service_name
  resource_group_name = data.azurerm_resource_group.target.name
}

data "azurerm_cognitive_account" "foundry" {
  name                = var.foundry_account_name
  resource_group_name = data.azurerm_resource_group.target.name
}

data "azurerm_service_plan" "existing" {
  count               = (var.deploy_api || var.deploy_ui) && var.existing_app_service_plan_name != null ? 1 : 0
  name                = var.existing_app_service_plan_name
  resource_group_name = data.azurerm_resource_group.target.name
}

data "azurerm_service_plan" "bot" {
  name                = var.bot_service_plan_name
  resource_group_name = data.azurerm_resource_group.target.name
}

locals {
  deploy_web_apps = var.deploy_api || var.deploy_ui
  use_existing_app_service_plan = local.deploy_web_apps && var.existing_app_service_plan_name != null
  location_slug = replace(lower(var.location), " ", "")
  service_plan_id = local.deploy_web_apps ? (local.use_existing_app_service_plan ? data.azurerm_service_plan.existing[0].id : azurerm_service_plan.main[0].id) : null
  web_app_location = local.deploy_web_apps ? (local.use_existing_app_service_plan ? data.azurerm_service_plan.existing[0].location : var.location) : null
  api_web_app_name = var.api_web_app_name != null ? var.api_web_app_name : azurecaf_name.api_web_app.result
  ui_web_app_name = var.ui_web_app_name != null ? var.ui_web_app_name : azurecaf_name.ui_web_app.result
}

resource "azurecaf_name" "app_service_plan" {
  name          = var.name_prefix
  resource_type = "azurerm_app_service_plan"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "api_web_app" {
  name          = "${var.name_prefix}api"
  resource_type = "azurerm_linux_web_app"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "ui_web_app" {
  name          = "${var.name_prefix}ui"
  resource_type = "azurerm_linux_web_app"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "api_identity" {
  name          = "${var.name_prefix}api"
  resource_type = "azurerm_user_assigned_identity"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "ui_identity" {
  name          = "${var.name_prefix}ui"
  resource_type = "azurerm_user_assigned_identity"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "vnet" {
  name          = var.name_prefix
  resource_type = "azurerm_virtual_network"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "private_endpoint_foundry" {
  name          = "${var.name_prefix}fdry"
  resource_type = "azurerm_private_endpoint"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "private_endpoint_search" {
  name          = "${var.name_prefix}srch"
  resource_type = "azurerm_private_endpoint"
  suffixes      = [local.location_slug]
}

resource "azurecaf_name" "log_analytics" {
  name          = var.name_prefix
  resource_type = "azurerm_log_analytics_workspace"
  suffixes      = [local.location_slug]
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = azurecaf_name.log_analytics.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "api" {
  count               = var.deploy_api ? 1 : 0
  name                = azurecaf_name.api_identity.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "ui" {
  count               = var.deploy_ui ? 1 : 0
  name                = azurecaf_name.ui_identity.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  tags                = var.tags
}

resource "azurerm_virtual_network" "main" {
  name                = azurecaf_name.vnet.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  address_space       = ["10.40.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "appsvc_integration" {
  name                 = "appsvc-integration"
  resource_group_name  = data.azurerm_resource_group.target.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.40.1.0/24"]

  delegation {
    name = "appsvc"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                                      = "private-endpoints"
  resource_group_name                       = data.azurerm_resource_group.target.name
  virtual_network_name                      = azurerm_virtual_network.main.name
  address_prefixes                          = ["10.40.2.0/24"]
  service_endpoints                         = ["Microsoft.CognitiveServices"]
  private_endpoint_network_policies         = "Disabled"
  private_link_service_network_policies_enabled = false

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_private_dns_zone" "foundry" {
  name                = "privatelink.services.ai.azure.com"
  resource_group_name = data.azurerm_resource_group.target.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone" "search" {
  name                = "privatelink.search.windows.net"
  resource_group_name = data.azurerm_resource_group.target.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  name                  = "foundry-link"
  resource_group_name   = data.azurerm_resource_group.target.name
  private_dns_zone_name = azurerm_private_dns_zone.foundry.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "search" {
  name                  = "search-link"
  resource_group_name   = data.azurerm_resource_group.target.name
  private_dns_zone_name = azurerm_private_dns_zone.search.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "foundry" {
  name                = azurecaf_name.private_endpoint_foundry.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "foundry-private-link"
    private_connection_resource_id = var.foundry_account_resource_id
    is_manual_connection           = false
    subresource_names              = ["account"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.foundry.id]
  }
}

resource "azurerm_private_endpoint" "search" {
  name                = azurecaf_name.private_endpoint_search.result
  location            = var.location
  resource_group_name = data.azurerm_resource_group.target.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "search-private-link"
    private_connection_resource_id = data.azurerm_search_service.target.id
    is_manual_connection           = false
    subresource_names              = ["searchService"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.search.id]
  }
}

resource "azurerm_service_plan" "main" {
  count               = local.deploy_web_apps && var.existing_app_service_plan_name == null ? 1 : 0
  name                = azurecaf_name.app_service_plan.result
  resource_group_name = data.azurerm_resource_group.target.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_plan_sku
  tags                = var.tags
}

resource "azurerm_linux_web_app" "api" {
  count               = var.deploy_api ? 1 : 0
  name                = local.api_web_app_name
  resource_group_name = data.azurerm_resource_group.target.name
  location            = local.web_app_location
  service_plan_id     = local.service_plan_id
  https_only          = true
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = !local.use_existing_app_service_plan || lower(data.azurerm_service_plan.existing[0].location) == lower(var.location)
      error_message = "The existing App Service plan must be in the same region as the deployment VNet and web apps. Set existing_app_service_plan_name to null to create a new plan in ${var.location}, or point it to an App Service plan in ${var.location}."
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api[0].id]
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    WEBSITE_RUN_FROM_PACKAGE       = "1"
    APIM_GATEWAY_URL               = data.azurerm_api_management.apim.gateway_url
    APIM_SUBSCRIPTION_KEY          = ""
    ALLOWED_ORIGINS                = "https://${local.ui_web_app_name}.azurewebsites.net,http://localhost:4200"
  }

  site_config {
    always_on         = true
    ftps_state        = "Disabled"
    health_check_path = "/api/health"
    health_check_eviction_time_in_min = 2
    app_command_line  = "gunicorn --bind=0.0.0.0 --timeout 600 -k uvicorn.workers.UvicornWorker api.server:app"

    application_stack {
      python_version = "3.11"
    }
  }
}

resource "azurerm_linux_web_app" "ui" {
  count               = var.deploy_ui ? 1 : 0
  name                = local.ui_web_app_name
  resource_group_name = data.azurerm_resource_group.target.name
  location            = local.web_app_location
  service_plan_id     = local.service_plan_id
  https_only          = true
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = !local.use_existing_app_service_plan || lower(data.azurerm_service_plan.existing[0].location) == lower(var.location)
      error_message = "The existing App Service plan must be in the same region as the deployment VNet and web apps. Set existing_app_service_plan_name to null to create a new plan in ${var.location}, or point it to an App Service plan in ${var.location}."
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ui[0].id]
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    WEBSITE_RUN_FROM_PACKAGE       = "1"
    PORT                           = "8080"
    API_BASE_URL                   = "${data.azurerm_api_management.apim.gateway_url}/foundry-privatevnet-app/api"
  }

  site_config {
    always_on  = true
    ftps_state = "Disabled"
    app_command_line = "pm2 serve /home/site/wwwroot 8080 --no-daemon --spa"

    application_stack {
      node_version = "20-lts"
    }
  }
}

resource "azurerm_app_service_virtual_network_swift_connection" "api" {
  count          = var.deploy_api ? 1 : 0
  app_service_id = azurerm_linux_web_app.api[0].id
  subnet_id      = azurerm_subnet.appsvc_integration.id
}

resource "azurerm_app_service_virtual_network_swift_connection" "ui" {
  count          = var.deploy_ui ? 1 : 0
  app_service_id = azurerm_linux_web_app.ui[0].id
  subnet_id      = azurerm_subnet.appsvc_integration.id
}

resource "azurerm_monitor_diagnostic_setting" "api" {
  count                      = var.deploy_api ? 1 : 0
  name                       = "api-to-law"
  target_resource_id         = azurerm_linux_web_app.api[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceAppLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "ui" {
  count                      = var.deploy_ui ? 1 : 0
  name                       = "ui-to-law"
  target_resource_id         = azurerm_linux_web_app.ui[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceAppLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# =============================================================================
# Bot Web App — receives Teams messages and proxies to APIM /chat
# =============================================================================

resource "azurerm_linux_web_app" "bot" {
  name                = "func-${var.name_prefix}-bot-${local.location_slug}"
  resource_group_name = data.azurerm_resource_group.target.name
  location            = data.azurerm_service_plan.bot.location
  service_plan_id     = data.azurerm_service_plan.bot.id
  tags                = var.tags

  site_config {
    application_stack {
      python_version = "3.11"
    }
    app_command_line = "gunicorn --bind=0.0.0.0 --timeout 600 -k aiohttp.GunicornWebWorker bot_app:app"
  }

  app_settings = {
    "MicrosoftAppId"        = var.bot_app_id
    "MicrosoftAppPassword"  = var.bot_app_password
    "MicrosoftAppType"      = "SingleTenant"
    "MicrosoftAppTenantId"  = data.azurerm_client_config.current.tenant_id
    "APIM_CHAT_URL"         = "https://${data.azurerm_api_management.apim.gateway_url}/foundry-privatevnet-app/chat"
  }
}

resource "azapi_resource" "bot_registration" {
  type      = "Microsoft.BotService/botServices@2022-09-15"
  name      = "foundry-privatevnet-bot"
  location  = "global"
  parent_id = data.azurerm_resource_group.target.id
  tags      = var.tags

  body = {
    sku = {
      name = "F0"
    }
    kind = "azurebot"
    properties = {
      displayName                         = "Foundry Private VNET Bot"
      endpoint                            = "https://${azurerm_linux_web_app.bot.default_hostname}/api/messages"
      msaAppId                            = var.bot_app_id
      msaAppType                          = "SingleTenant"
      msaAppTenantId                      = data.azurerm_client_config.current.tenant_id
    }
  }
}

resource "azapi_resource" "bot_teams_channel" {
  type      = "Microsoft.BotService/botServices/channels@2022-09-15"
  name      = "MsTeamsChannel"
  parent_id = azapi_resource.bot_registration.id

  body = {
    properties = {
      channelName = "MsTeamsChannel"
      properties = {
        isEnabled = true
      }
    }
  }
}
