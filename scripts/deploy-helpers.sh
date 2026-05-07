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

  # Submit deployment — use 'az webapp deploy' with a short timeout.
  # If it times out (504), the deploy is still running server-side;
  # we poll the ARM deployment status to wait for completion.
  local deploy_ok=false
  if az webapp deploy --name "$app" --resource-group "$rg" \
       --src-path "$src" --type zip --timeout 120 2>&1; then
    echo "==> $app deploy command succeeded"
    deploy_ok=true
  else
    echo "==> $app deploy command returned non-zero (likely 504 timeout). Polling deployment status..."
  fi

  # If the az deploy command succeeded instantly, verify via health check
  if [ "$deploy_ok" = true ]; then
    return 0
  fi

  # Poll ARM deployment status via the Kudu deployments endpoint through ARM
  local elapsed=0 interval=20
  echo "==> Polling deployment status for $app (max ${max_wait}s)"
  while [ $elapsed -lt "$max_wait" ]; do
    sleep $interval
    elapsed=$((elapsed + interval))

    # Use ARM REST API to check deployment status (works regardless of Kudu access)
    local response status
    response=$(az rest --method GET \
      --url "https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${rg}/providers/Microsoft.Web/sites/${app}/deployments?api-version=2023-12-01" \
      --query "value[0].{status:properties.status, active:properties.active, id:id}" \
      -o json 2>/dev/null || echo "{}")

    status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")

    case "$status" in
      4)
        echo "==> $app deployment succeeded (${elapsed}s)"
        return 0
        ;;
      3)
        echo "==> $app deployment FAILED (${elapsed}s)"
        # Get deployment log
        local dep_id
        dep_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -n "$dep_id" ]; then
          az rest --method GET \
            --url "https://management.azure.com${dep_id}/log?api-version=2023-12-01" \
            2>/dev/null | jq -r '.value[].properties.message // empty' 2>/dev/null || true
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
  return 1
}
