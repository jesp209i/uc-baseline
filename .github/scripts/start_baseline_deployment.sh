#!/bin/bash

# Starts a deployment of an artifact uploaded to a baseline project onto one of its connected child projects.
# Modelled on https://github.com/umbraco/Umbraco.Cloud.CICDFlow.Samples/blob/main/V2/bash/start_deployment.sh
#
# Usage:
#   start_baseline_deployment.sh <baselineProjectId> <apiKey> <childProjectId> <artifactId> <targetEnvironmentAlias> <commitMessage> \
#     [noBuildAndRestore=false] [skipVersionCheck=false] [runSchemaExtraction=true] <pipelineVendor> [baseUrl]
#
# The api key is the baseline project's key, and the artifact must have been uploaded to the baseline project.
# The target must be the child's leftmost mainline environment or a flexible environment.
# umbraco-cloud.json on the child is always preserved, so there is no skipPreserveUmbracoCloudJson option.

# Set variables
baselineProjectId="$1"
apiKey="$2"
childProjectId="$3"
artifactId="$4"
targetEnvironmentAlias="$5"
commitMessage="$6"
noBuildAndRestore="${7:-false}"
skipVersionCheck="${8:-false}"
runSchemaExtraction="${9:-true}"
pipelineVendor="${10}"

# Not required, defaults to https://api.cloud.umbraco.com
baseUrl="${11:-https://api.dev-cloud.umbraco.com}"

for requiredVariable in baselineProjectId apiKey childProjectId artifactId targetEnvironmentAlias commitMessage; do
  if [[ -z "${!requiredVariable}" ]]; then
    echo "Missing required argument: $requiredVariable"
    exit 1
  fi
done

for booleanVariable in noBuildAndRestore skipVersionCheck runSchemaExtraction; do
  if [[ "${!booleanVariable}" != "true" && "${!booleanVariable}" != "false" ]]; then
    echo "Argument $booleanVariable must be 'true' or 'false', got '${!booleanVariable}'"
    exit 1
  fi
done

url="$baseUrl/v2/baseline/$baselineProjectId/deployments"

# Define function to call API to start the deployment
function call_api {
  echo "Requesting start Baseline Deployment at $url with options:"
  echo " - childProjectId: $childProjectId"
  echo " - targetEnvironmentAlias: $targetEnvironmentAlias"
  echo " - artifactId: $artifactId"
  echo " - commitMessage: $commitMessage"
  echo " - noBuildAndRestore: $noBuildAndRestore"
  echo " - skipVersionCheck: $skipVersionCheck"
  echo " - runSchemaExtraction: $runSchemaExtraction"

  # Build the body with jq so quotes or newlines in the commit message can't break the JSON
  requestBody=$(jq -n \
    --arg childProjectId "$childProjectId" \
    --arg targetEnvironmentAlias "$targetEnvironmentAlias" \
    --arg artifactId "$artifactId" \
    --arg commitMessage "$commitMessage" \
    --argjson noBuildAndRestore "$noBuildAndRestore" \
    --argjson skipVersionCheck "$skipVersionCheck" \
    --argjson runSchemaExtraction "$runSchemaExtraction" \
    '{childProjectId: $childProjectId, targetEnvironmentAlias: $targetEnvironmentAlias, artifactId: $artifactId, commitMessage: $commitMessage, noBuildAndRestore: $noBuildAndRestore, skipVersionCheck: $skipVersionCheck, runSchemaExtraction: $runSchemaExtraction}')

  response=$(curl -s -w "%{http_code}" -X POST "$url" \
    -H "Umbraco-Cloud-Api-Key: $apiKey" \
    -H "Content-Type: application/json" \
    -d "$requestBody")

  curlExitCode=$?
  responseCode=${response: -3}
  content=${response%???}

  if [[ $curlExitCode -ne 0 || "$responseCode" == "000" ]]; then
    echo "Could not reach $url (curl exit code $curlExitCode)"
    exit 1
  fi

  echo "--- --- ---"
  echo "Response:"
  echo "$content"

  if (( 10#$responseCode == 201 )); then
    deployment_id=$(echo "$content" | jq -r '.deploymentId')

    if [[ "$pipelineVendor" == "GITHUB" ]]; then
      echo "deploymentId=$deployment_id" >> "$GITHUB_OUTPUT"
      echo "childProjectId=$childProjectId" >> "$GITHUB_OUTPUT"
    elif [[ "$pipelineVendor" == "AZUREDEVOPS" ]]; then
      echo "##vso[task.setvariable variable=deploymentId;isOutput=true]$deployment_id"
      echo "##vso[task.setvariable variable=childProjectId;isOutput=true]$childProjectId"
    elif [[ "$pipelineVendor" == "TESTRUN" ]]; then
      echo $pipelineVendor
    else
      echo "Please use one of the supported Pipeline Vendors or enhance script to fit your needs"
      echo "Currently supported are: GITHUB and AZUREDEVOPS"
      exit 1
    fi

    echo "--- --- ---"
    echo "Baseline Deployment started successfully -> $deployment_id on child project $childProjectId"
    exit 0
  fi

  if (( 10#$responseCode == 404 )); then
    echo "Project $childProjectId is not a connected child of baseline project $baselineProjectId"
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

call_api
