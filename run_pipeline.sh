#!/usr/bin/env bash

set -e

# Usage information
usage() {
    echo "Usage: $0 <repository-name>"
    echo ""
    echo "Available repositories:"
    yq eval '.repositories | keys | .[]' repos.yaml | sed 's/^/  - /'
    exit 1
}

# Check if repository name is provided
REPO_NAME=$1
if [ -z "$REPO_NAME" ]; then
    echo "Error: Repository name is required"
    usage
fi

# Check if repos.yaml exists
if [ ! -f "repos.yaml" ]; then
    echo "Error: repos.yaml not found"
    exit 1
fi

# Check if yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed"
    echo "Install it with: brew install yq"
    exit 1
fi

# Validate ConfigMap repository environment variables
if [ ! -n "${CONFIGMAP_REPO}" ]; then
    echo "Error: CONFIGMAP_REPO environment variable is not set"
    echo "Example: export CONFIGMAP_REPO=git@gitlab.example.com:org/configmaps.git"
    exit 1
fi

# Set default for ConfigMap branch if not specified
CONFIGMAP_BRANCH=${CONFIGMAP_BRANCH:-main}

# Parse repository-specific settings
echo "Loading configuration for repository: $REPO_NAME"

# Check if repository exists
if ! yq eval ".repositories | has(\"$REPO_NAME\")" repos.yaml | grep -q "true"; then
    echo "Error: Repository '$REPO_NAME' not found in repos.yaml"
    usage
fi

# Extract PipelineRun file
PIPELINERUN_FILE=$(yq eval ".repositories.$REPO_NAME.pipelinerun" repos.yaml)

if [ -z "$PIPELINERUN_FILE" ] || [ "$PIPELINERUN_FILE" = "null" ]; then
    echo "Error: pipelinerun not defined for repository '$REPO_NAME'"
    exit 1
fi

PIPELINERUN_PATH="pipelineruns/$PIPELINERUN_FILE"
if [ ! -f "$PIPELINERUN_PATH" ]; then
    echo "Error: PipelineRun file not found: $PIPELINERUN_PATH"
    exit 1
fi

# Extract ConfigMap paths
mapfile -t CONFIGMAP_PATHS < <(yq eval ".repositories.$REPO_NAME.configmaps[].path" repos.yaml)

# Validate environment variables
if [ ! -n "${E2E_USER}" ]; then
    echo "Error: E2E_USER environment variable is not set"
    exit 1
fi

if [ ! -n "${E2E_PASSWORD}" ]; then
    echo "Error: E2E_PASSWORD environment variable is not set"
    exit 1
fi

if [ ! -n "${E2E_PROXY_URL}" ]; then
    echo "Error: E2E_PROXY_URL environment variable is not set"
    exit 1
fi

if [ ! -n "${STAGE_ACTUAL_HOSTNAME}" ]; then
    echo "Error: STAGE_ACTUAL_HOSTNAME environment variable is not set"
    exit 1
fi

if [ ! -n "${HTTP_PROXY}" ]; then
    echo "Error: HTTP_PROXY environment variable is not set"
    exit 1
fi

if [ ! -n "${HTTPS_PROXY}" ]; then
    echo "Error: HTTPS_PROXY environment variable is not set"
    exit 1
fi

# Set defaults for optional environment variables
export HCC_ENV=${HCC_ENV:-stage}
export BRANCH_NAME=${BRANCH_NAME:-main}

# Validate required envsubst variables
if [ ! -n "${SOURCE_ARTIFACT}" ]; then
    echo "Error: SOURCE_ARTIFACT environment variable is not set"
    echo "Example: export SOURCE_ARTIFACT=quay.io/org/app:latest"
    exit 1
fi

if [ ! -n "${HCC_ENV_URL}" ]; then
    echo "Error: HCC_ENV_URL environment variable is not set"
    exit 1
fi

echo ""
echo "=== Configuration Summary ==="
echo "Repository: $REPO_NAME"
echo "PipelineRun: $PIPELINERUN_PATH"
echo "Branch: $BRANCH_NAME"
echo "Source Artifact: $SOURCE_ARTIFACT"
echo "ConfigMap Repo: $CONFIGMAP_REPO"
echo "ConfigMap Branch: $CONFIGMAP_BRANCH"
echo "ConfigMaps to apply: ${#CONFIGMAP_PATHS[@]}"
for path in "${CONFIGMAP_PATHS[@]}"; do
    echo "  - $path"
done
echo "============================"
echo ""

# Clone or update the ConfigMap repository
CONFIGMAP_CACHE_DIR=".configmaps-cache"
echo "Fetching ConfigMaps from external repository..."

if [ -d "$CONFIGMAP_CACHE_DIR" ]; then
    echo "Updating existing ConfigMap repository cache..."
    cd "$CONFIGMAP_CACHE_DIR"
    git fetch origin
    git checkout "$CONFIGMAP_BRANCH"
    git pull origin "$CONFIGMAP_BRANCH"
    cd ..
else
    echo "Cloning ConfigMap repository..."
    git clone --branch "$CONFIGMAP_BRANCH" "$CONFIGMAP_REPO" "$CONFIGMAP_CACHE_DIR"
fi

# Validate that all ConfigMap files exist
echo "Validating ConfigMap files..."
for path in "${CONFIGMAP_PATHS[@]}"; do
    CONFIGMAP_FILE="$CONFIGMAP_CACHE_DIR/$path"
    if [ ! -f "$CONFIGMAP_FILE" ]; then
        echo "Error: ConfigMap file not found: $CONFIGMAP_FILE"
        exit 1
    fi
    echo "  ✓ Found: $path"
done

echo ""
echo "Clearing out previous pipeline run (if present)..."
yes | tkn pipelinerun delete e2e-pipeline-run 2>/dev/null || true

sleep 5

echo ""
echo "Applying shared E2E pipeline definition (ConfigMap, Task, Pipeline)..."
kubectl apply --filename shared-e2e-pipeline.yaml

echo ""
echo "Applying repository-specific ConfigMaps..."
CURRENT_NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}')
CURRENT_NAMESPACE=${CURRENT_NAMESPACE:-default}
for path in "${CONFIGMAP_PATHS[@]}"; do
    CONFIGMAP_FILE="$CONFIGMAP_CACHE_DIR/$path"
    echo "  Applying: $path (to namespace: $CURRENT_NAMESPACE)"
    # Strip the namespace from the ConfigMap YAML and apply to current namespace
    yq eval 'del(.metadata.namespace)' "$CONFIGMAP_FILE" | kubectl apply --filename - --namespace "$CURRENT_NAMESPACE"
done

echo ""
echo "Applying PipelineRun with environment variable substitution..."
envsubst < "$PIPELINERUN_PATH" | kubectl apply --filename -

# Wait for pods to start
echo ""
echo "Waiting for pods to spin up..."
sleep 6

# Follow logs
echo ""
echo "=== PipelineRun Logs ==="
tkn pipelinerun logs -f
