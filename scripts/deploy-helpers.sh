#!/usr/bin/env bash
# Shared deployment helper: ARM-based zip deploy with status polling.
# Source this file in GitHub Actions steps:
#   source scripts/deploy-helpers.sh
#   deploy_and_wait <app-name> <resource-group> <zip-path> <max-wait-seconds>

set -euo pipefail

deploy_and_wait() {
  local app="$1" rg="$2" src="$3" max_wait="${4:-600}"

  echo "==> Deploying $app via az webapp deploy"

  # Get subscription for ARM polling
  local sub_id
  sub_id=$(az account show --query id -o tsv)

  # Submit deployment with clean/restart semantics.
  # If it times out (504), the deploy may still be running server-side;
  # we poll deployment status to wait for completion.
  local deploy_ok=false
  local deploy_output=""
  if deploy_output=$(az webapp deploy --name "$app" --resource-group "$rg" \
       --src-path "$src" --type zip --clean true --restart true --timeout 180 2>&1); then
    echo "==> $app deploy command succeeded"
    deploy_ok=true
  else
    echo "$deploy_output"

    # Kudu can intermittently return 503 even when the app is recoverable.
    # Restart once and retry submission before entering long polling.
    if echo "$deploy_output" | grep -qi "Status Code: 503"; then
      echo "==> $app returned 503 from deployment endpoint. Restarting app and retrying once..."
      az webapp restart --name "$app" --resource-group "$rg" --output none || true
      sleep 20
      if deploy_output=$(az webapp deploy --name "$app" --resource-group "$rg" \
           --src-path "$src" --type zip --clean true --restart true --timeout 300 2>&1); then
        echo "==> $app deploy retry succeeded"
        deploy_ok=true
      else
        echo "$deploy_output"
      fi
    fi

  fi

  if [ "$deploy_ok" = false ]; then
    echo "==> $app deploy command returned non-zero (likely 504 timeout). Polling deployment status..."
  fi

  # If the az deploy command succeeded instantly, verify via health check
  if [ "$deploy_ok" = true ]; then
    return 0
  fi

  # Poll deployment status via ARM first, then fallback to CLI deployment list.
  local elapsed=0 interval=20
  echo "==> Polling deployment status for $app (max ${max_wait}s)"
  while [ $elapsed -lt "$max_wait" ]; do
    sleep $interval
    elapsed=$((elapsed + interval))

    # Use ARM REST API to check deployment status (works regardless of Kudu basic auth)
    local response deployment status dep_id
    response=$(az rest --method GET \
      --url "https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${rg}/providers/Microsoft.Web/sites/${app}/deployments?api-version=2023-12-01" \
      -o json 2>/dev/null || echo '{"value":[]}')

    deployment=$(echo "$response" | jq -c '(.value // []) | (map(select(.properties.active == true)) | .[0]) // .[0] // {}' 2>/dev/null || echo '{}')
    status=$(echo "$deployment" | jq -r '.properties.status // empty' 2>/dev/null || echo "")
    dep_id=$(echo "$deployment" | jq -r '.id // empty' 2>/dev/null || echo "")

    # Fallback if ARM status is empty: use CLI deployment listing.
    if [ -z "$status" ]; then
      status=$(az webapp log deployment list --name "$app" --resource-group "$rg" --query "[0].status" -o tsv 2>/dev/null || echo "")
    fi

    case "$status" in
      4)
        echo "==> $app deployment succeeded (${elapsed}s)"
        return 0
        ;;
      3)
        echo "==> $app deployment FAILED (${elapsed}s)"
        # Get deployment log
        if [ -n "$dep_id" ]; then
          az rest --method GET \
            --url "https://management.azure.com${dep_id}/log?api-version=2023-12-01" \
            2>/dev/null | jq -r '.value[].properties.message // empty' 2>/dev/null || true
        else
          az webapp log deployment list --name "$app" --resource-group "$rg" \
            --query "[0].{status:status,message:message,log:log_url}" -o json 2>/dev/null || true
        fi
        return 1
        ;;
      "")
        echo "    $app deploying... (${elapsed}/${max_wait}s)"
        ;;
      *)
        echo "    $app deploying... (${elapsed}/${max_wait}s, status=$status)"
        ;;
    esac
  done

  echo "==> $app deployment timed out after ${max_wait}s"
  echo "==> Last known deployment snapshot:"
  az webapp log deployment list --name "$app" --resource-group "$rg" \
    --query "[0].{status:status,message:message,author:author,end_time:end_time,log:log_url}" -o json 2>/dev/null || true
  return 1
}
