#!/usr/bin/env bash
# Shared deployment helper: async zip deploy + Kudu status polling.
# Source this file in GitHub Actions steps:
#   source scripts/deploy-helpers.sh
#   deploy_and_wait <app-name> <resource-group> <zip-path> <max-wait-seconds>

set -euo pipefail

deploy_and_wait() {
  local app="$1" rg="$2" src="$3" max_wait="${4:-300}"

  echo "==> Deploying $app via Kudu async zipdeploy"

  # Get Azure bearer token for Kudu (works even when basic auth is disabled)
  local token
  token=$(az account get-access-token --query accessToken -o tsv)

  # Submit deployment via Kudu zipdeploy API (async — returns 202 immediately)
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://${app}.scm.azurewebsites.net/api/zipdeploy?isAsync=true" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/zip" \
    --data-binary "@${src}" \
    --max-time 120)

  if [ "$http_code" != "202" ] && [ "$http_code" != "200" ]; then
    echo "ERROR: Kudu zipdeploy returned HTTP $http_code"
    if [ "$http_code" == "409" ]; then
      echo "Another deployment is in progress. Waiting for it to finish..."
    elif [ "$http_code" == "401" ] || [ "$http_code" == "403" ]; then
      echo "Auth failed. Ensure the deployment principal has Website Contributor on the App Service."
      return 1
    fi
  fi

  # Poll deployment status until complete
  local elapsed=0 interval=15
  echo "==> Polling deployment status for $app (max ${max_wait}s)"
  while [ $elapsed -lt "$max_wait" ]; do
    sleep $interval
    elapsed=$((elapsed + interval))

    # Refresh token if close to expiry (tokens last ~60 min, this is cheap)
    if [ $((elapsed % 300)) -eq 0 ]; then
      token=$(az account get-access-token --query accessToken -o tsv)
    fi

    local response status
    response=$(curl -s \
      -H "Authorization: Bearer $token" \
      "https://${app}.scm.azurewebsites.net/api/deployments/latest" 2>/dev/null || echo "{}")
    status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null || echo "")

    case "$status" in
      4)
        echo "==> $app deployment succeeded (${elapsed}s)"
        return 0
        ;;
      3)
        echo "==> $app deployment FAILED"
        curl -s -H "Authorization: Bearer $token" \
          "https://${app}.scm.azurewebsites.net/api/deployments/latest/log" \
          2>/dev/null | jq -r '.[].message // empty' 2>/dev/null || true
        return 1
        ;;
      "")
        # Empty status could mean no deployment yet or auth issue — check if we got a valid response
        local has_id
        has_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -z "$has_id" ] && [ $elapsed -ge 60 ]; then
          echo "WARNING: No deployment status after ${elapsed}s. Response: $(echo "$response" | head -c 200)"
        fi
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
