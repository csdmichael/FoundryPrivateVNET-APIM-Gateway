#!/usr/bin/env bash
# Shared deployment helper: async zip deploy + Kudu status polling.
# Source this file in GitHub Actions steps:
#   source scripts/deploy-helpers.sh
#   deploy_and_wait <app-name> <resource-group> <zip-path> <max-wait-seconds>

set -euo pipefail

deploy_and_wait() {
  local app="$1" rg="$2" src="$3" max_wait="${4:-300}"

  echo "==> Submitting async zip deploy for $app"

  # Get publishing credentials for Kudu status polling
  local creds user pass
  creds=$(az webapp deployment list-publishing-credentials \
    --name "$app" --resource-group "$rg" -o json 2>/dev/null)
  user=$(echo "$creds" | jq -r '.publishingUserName')
  pass=$(echo "$creds" | jq -r '.publishingPassword')

  # Submit deployment via Kudu zipdeploy API (async — returns 202 immediately)
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "https://${app}.scm.azurewebsites.net/api/zipdeploy?isAsync=true" \
    -u "$user:$pass" \
    -H "Content-Type: application/zip" \
    --data-binary "@${src}" \
    --max-time 120)

  if [ "$http_code" != "202" ] && [ "$http_code" != "200" ]; then
    echo "WARNING: Kudu zipdeploy returned HTTP $http_code (expected 202). Checking status anyway..."
  fi

  # Poll deployment status until complete
  local elapsed=0 interval=15
  echo "==> Polling deployment status for $app (max ${max_wait}s)"
  while [ $elapsed -lt "$max_wait" ]; do
    sleep $interval
    elapsed=$((elapsed + interval))

    local status
    status=$(curl -s -u "$user:$pass" \
      "https://${app}.scm.azurewebsites.net/api/deployments/latest" \
      2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")

    case "$status" in
      4)
        echo "==> $app deployment succeeded (${elapsed}s)"
        return 0
        ;;
      3)
        echo "==> $app deployment FAILED"
        # Print last deployment log for diagnostics
        curl -s -u "$user:$pass" \
          "https://${app}.scm.azurewebsites.net/api/deployments/latest/log" \
          2>/dev/null | jq -r '.[].message // empty' 2>/dev/null || true
        return 1
        ;;
      *)
        echo "    $app deploy in progress... (${elapsed}/${max_wait}s, status=$status)"
        ;;
    esac
  done

  echo "==> $app deployment timed out after ${max_wait}s"
  return 1
}
