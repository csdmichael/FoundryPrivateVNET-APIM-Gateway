output "resource_group_name" {
  value = data.azurerm_resource_group.target.name
}

output "virtual_network_name" {
  value = azurerm_virtual_network.main.name
}

output "api_web_app_name" {
  value = try(azurerm_linux_web_app.api[0].name, null)
}

output "ui_web_app_name" {
  value = try(azurerm_linux_web_app.ui[0].name, null)
}

output "api_url" {
  value = try("https://${azurerm_linux_web_app.api[0].default_hostname}", null)
}

output "ui_url" {
  value = try("https://${azurerm_linux_web_app.ui[0].default_hostname}", null)
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "foundry_private_endpoint_ip" {
  value = one(azurerm_private_endpoint.foundry.private_service_connection).private_ip_address
}

output "search_private_endpoint_ip" {
  value = one(azurerm_private_endpoint.search.private_service_connection).private_ip_address
}

output "bot_function_app_name" {
  value = azurerm_linux_web_app.bot.name
}

output "bot_function_url" {
  value = "https://${azurerm_linux_web_app.bot.default_hostname}/api/messages"
}

output "bot_app_id" {
  value = var.bot_app_id
}
