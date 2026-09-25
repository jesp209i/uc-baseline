#!/bin/bash

# Polls the status of a baseline deployment started with start_baseline_deployment.sh until it completes, fails or times out.
# Modelled on https://github.com/umbraco/Umbraco.Cloud.CICDFlow.Samples/blob/main/V2/bash/get_deployment_status.sh
#
# Usage:
#   get_baseline_deployment_status.sh <baselineProjectId> <apiKey> <deploymentId> [timeoutSeconds=1200] [baseUrl]
#
# The api key is the baseline project's key. The deployment must be on a child project connected to the baseline.

# Set variables
baselineProjectId="$1"
apiKey="$2"
deploymentId="$3"
timeoutSeconds="${4:-1200}"

# Not required, defaults to https://api.cloud.umbraco.com
baseUrl="${5:-https://api.cloud.umbraco.com}"

for requiredVariable in baselineProjectId apiKey deploymentId; do
  if [[ -z "${!requiredVariable}" ]]; then
    echo "Missing required argument: $requiredVariable"
    exit 1
  fi
done

if ! [[ "$timeoutSeconds" =~ ^[0-9]+$ ]]; then
  echo "Argument timeoutSeconds must be a whole number of seconds, got '$timeoutSeconds'"
  exit 1
fi

url="$baseUrl/v2/baseline/$baselineProjectId/deployments/$deploymentId"
pollIntervalSeconds=25
lastModifiedUtc=""

# Define function to call API to get the deployment status
function call_api {
  requestUrl="$url"
  if [[ -n "$lastModifiedUtc" ]]; then
    requestUrl="$url?lastModifiedUtc=$(jq -rn --arg value "$lastModifiedUtc" '$value | @uri')"
  fi

  response=$(curl -s -w "%{http_code}" -X GET "$requestUrl" \
    -H "Umbraco-Cloud-Api-Key: $apiKey" \
    -H "Content-Type: application/json")

  curlExitCode=$?
  responseCode=${response: -3}
  content=${response%???}

  if [[ $curlExitCode -ne 0 || "$responseCode" == "000" ]]; then
    echo "Could not reach $requestUrl (curl exit code $curlExitCode)"
    exit 1
  fi

  if (( 10#$responseCode == 200 )); then
    deploymentState=$(echo "$content" | jq -r '.deploymentState')
    modifiedUtc=$(echo "$content" | jq -r '.modifiedUtc // empty')
    if [[ -n "$modifiedUtc" ]]; then
      lastModifiedUtc="$modifiedUtc"
    fi

    # Only messages newer than lastModifiedUtc are returned, so everything here is new
    echo "$content" | jq -r '.deploymentStatusMessages[]? | "\(.timestampUtc): \(.message)"'
    return
  fi

  # A 404 from the Deployment service is ProblemDetails with a title; the gateway's own 404 (no matching route) has a message instead
  if (( 10#$responseCode == 404 )); then
    if [[ "$(echo "$content" | jq -r '.title // empty' 2>/dev/null)" == "Deployment not found" ]]; then
      echo "Deployment $deploymentId was not found on a child project connected to baseline project $baselineProjectId"
    else
      echo "The API gateway found no endpoint at $url - the baseline deployment status endpoint may not be available in this environment"
    fi
  fi

  ## Let errors bubble forward
  echo "Unexpected API Response Code: $responseCode - More details below"
  # Check if the response is valid JSON
  if echo "$content" | jq . > /dev/null 2>&1; then
    printf -- "--- Response JSON formatted ---\n"
    echo "$content" | jq .
  else
    printf -- "--- Response RAW ---\n"
    echo "$content"
  fi
  printf "\n---Response End---\n"
  exit 1
}

echo "Polling Baseline Deployment status at $url every $pollIntervalSeconds seconds (timeout $timeoutSeconds seconds)"

startTime=$(date +%s)
while true; do
  call_api

  echo "Deployment state: $deploymentState"

  if [[ "$deploymentState" == "Completed" ]]; then
    echo "--- --- ---"
    echo "Baseline Deployment $deploymentId completed successfully"
    exit 0
  fi

  if [[ "$deploymentState" == "Failed" ]]; then
    echo "--- --- ---"
    echo "Baseline Deployment $deploymentId failed"
    exit 1
  fi

  elapsedSeconds=$(( $(date +%s) - startTime ))
  if (( elapsedSeconds >= timeoutSeconds )); then
    echo "--- --- ---"
    echo "Timed out after $elapsedSeconds seconds waiting for Baseline Deployment $deploymentId - last state: $deploymentState"
    exit 1
  fi

  sleep $pollIntervalSeconds
done
