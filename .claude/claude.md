# Local Minikube Tekton

This repository contains a Tekton pipeline for running E2E Playwright tests locally using Minikube.

## Overview

The project sets up a local Tekton pipeline environment to test web applications with E2E tests. The testing environment uses:

- **git-clone task**: Clones the source repository containing E2E tests
- **run-application sidecar**: Runs the application under test from a container image
- **frontend-development-proxy sidecar**: Provides proxy access to resources from the stage environment
- **insights-chrome-dev sidecar**: Serves chrome UI static assets locally on port 9912
- **Playwright**: Executes E2E tests against the running application

## Architecture

The Tekton pipeline orchestrates:

1. **fetch-source**: Clones the source repository using the git-clone task
2. **e2e-test-run**: Executes the e2e-task which:
   - Runs Playwright tests from the cloned source
   - Uses sidecars:
     - `frontend-dev-proxy`: Proxies stage environment resources using custom routes configuration
     - `insights-chrome-dev`: Serves chrome UI assets on port 9912 using Caddy
     - `run-application`: Runs the application from SOURCE_ARTIFACT image

## Files

### Core Pipeline Files
- `shared-e2e-pipeline.yaml`: Combined file containing:
  - Caddy ConfigMap for insights-chrome-dev Caddyfile configuration
  - Tekton Task definition for E2E testing
  - Tekton Pipeline definition
- `repos.yaml`: Central configuration file defining:
  - List of supported frontend repositories
  - ConfigMap paths for each repository in the external ConfigMap repository
  - PipelineRun file mapping for each repository
- `pipelineruns/`: Directory containing pre-generated PipelineRun YAML templates:
  - `frontend-starter-app.yaml`: PipelineRun for frontend-starter-app repository
  - `learning-resources.yaml`: PipelineRun for learning-resources repository
  - `README.md`: Documentation for adding new repositories

### Cluster Setup Scripts (`cluster_setup/`)
- `start.sh`: Initializes Minikube with podman driver (40GB disk, cri-o runtime)
- `install_tekton.sh`: Installs Tekton pipelines and git-clone task from Tekton Hub
- `image_load.sh`: Pre-loads container images into Minikube to avoid Docker Hub rate limiting

### Playwright Image (`playwright_image/`)
- `Dockerfile`: Defines the Playwright test image (based on mcr.microsoft.com/playwright:v1.50.0-noble with bind9 utilities)
- `build_and_push.sh`: Script to build and push the Playwright image to Quay.io

### Execution Scripts
- `run_pipeline.sh`: Main execution script that:
  - Takes a repository name as argument (e.g., `./run_pipeline.sh frontend-starter-app`)
  - Parses `repos.yaml` using `yq` to extract repository configuration
  - Validates required environment variables
  - Clones/updates external ConfigMap repository to `.configmaps-cache/`
  - Strips namespaces from ConfigMaps and applies them to current namespace
  - Applies repository-specific PipelineRun with environment variable substitution
  - Follows pipeline logs

### Helper Scripts (`helper_scripts/`)
- `browse_locally.sh`: Helper script for local browsing (opens https://stage.foo.redhat.com:1337)
- `forward.sh`: Port forwarding helper script (forwards port 1337 from pod to localhost)

## Prerequisites

- Minikube
- Podman (used as minikube driver)
- kubectl
- tkn (Tekton CLI)
- yq (for YAML parsing in run_pipeline.sh - install with `brew install yq`)
- envsubst (for environment variable substitution in pipeline runs)

## Getting Started

1. Set required environment variables:
   ```bash
   # ConfigMap repository (external repository containing Caddy config for all apps)
   export CONFIGMAP_REPO="git@gitlab.example.com:org/configmaps.git"
   export CONFIGMAP_BRANCH="main"  # Optional, defaults to main

   # Test credentials and proxy configuration
   export E2E_USER="your-test-username"
   export E2E_PASSWORD="your-test-password"
   export E2E_PROXY_URL="your-proxy-url"
   export HTTP_PROXY="your-http-proxy"
   export HTTPS_PROXY="your-https-proxy"
   export STAGE_ACTUAL_HOSTNAME="actual-stage-hostname.example.com"
   export HCC_ENV_URL="https://your-environment-url"

   # Repository-specific configuration
   export SOURCE_ARTIFACT="quay.io/org/app:tag"
   export BRANCH_NAME="main"  # Optional, defaults to main
   export HCC_ENV="stage"  # Optional, defaults to stage
   ```

2. Start Minikube:
   ```bash
   ./cluster_setup/start.sh
   ```

3. Install Tekton and required tasks:
   ```bash
   ./cluster_setup/install_tekton.sh
   ```

4. (Optional) Pre-load images to avoid Docker Hub rate limiting:
   ```bash
   ./cluster_setup/image_load.sh
   ```

5. Run the E2E pipeline for a specific repository:
   ```bash
   ./run_pipeline.sh frontend-starter-app
   # or
   ./run_pipeline.sh learning-resources
   ```

   This script will:
   - Parse `repos.yaml` to extract configuration for the specified repository
   - Validate required environment variables
   - Clone/update the external ConfigMap repository to `.configmaps-cache/`
   - Apply ConfigMaps (with namespace stripped) to current namespace
   - Apply the shared E2E pipeline definition (Task, Pipeline)
   - Apply the repository-specific PipelineRun with environment variable substitution
   - Follow the logs

## Configuration

### Pipeline Parameters

- `branch-name`: Git branch to clone from the test repository
- `repo-url`: Repository URL containing the E2E tests
- `SOURCE_ARTIFACT`: Container image containing the application to test
- `E2E_USER`: Username for E2E test authentication
- `E2E_PASSWORD`: Password for E2E test authentication
- `e2e_proxy`: HTTP proxy URL for external requests
- `STAGE_ACTUAL_HOSTNAME`: Actual stage environment hostname (used in catch-all handler to bypass hostAliases DNS override)
- `HCC_ENV_URL`: HCC environment URL (used for environment variable substitution in proxy configuration)
- `proxy-routes`: Custom proxy routes configuration (Caddy directives format)
- `e2e-tests-script`: Custom test execution script (optional override)
- `PLAYWRIGHT_IMAGE`: Playwright container image (default: `mcr.microsoft.com/playwright:v1.58.0-noble`)
- `CHROME_DEV_IMAGE`: Chrome dev container image (default: `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`)
- `PROXY_IMAGE`: Frontend proxy container image (default: `quay.io/redhat-user-workloads/hcc-platex-services-tenant/frontend-development-proxy:latest`)
- `APP_PORT`: Application port (default: `8000`)

### Workspaces

- `shared-code-workspace`: PersistentVolumeClaim (2Gi) that persists cloned source code between pipeline tasks
  - Mounted at `/workspace/output` in the git-clone task and e2e-task
  - Uses `volumeClaimTemplate` for automatic PVC creation

### Sidecars Configuration

The e2e-task runs three sidecars alongside the Playwright test step:

1. **frontend-dev-proxy**: Proxies requests to external resources and sidecars
   - Image: `quay.io/redhat-user-workloads/hcc-platex-services-tenant/frontend-development-proxy:latest`
   - Serves TLS on port 1337 for `stage.foo.redhat.com`
   - Custom routes defined in `/config/routes` (written dynamically from `PROXY_ROUTES_JSON` parameter)
   - Performs environment variable substitution in Caddyfile (`$LOCAL_ROUTES`, `$HCC_ENV_URL`, etc.)
   - Waits for route configuration to be written before starting
   - Waits for insights-chrome-dev (port 9912) and run-application (port 8000) to be ready before starting
   - Enables debug mode and admin API on port 2019

2. **insights-chrome-dev**: Serves chrome UI static assets
   - Image: `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`
   - Runs Caddy web server on port 9912
   - Configuration in `/etc/caddy/Caddyfile` (mounted from ConfigMap in `shared-e2e-pipeline.yaml`)
   - Serves files from `/opt/app-root/src/build/stable`
   - Strips `/apps/chrome` prefix for SPA routing
   - CORS enabled for cross-origin access

3. **run-application**: Runs the application under test
   - Image: Specified by `SOURCE_ARTIFACT` parameter
   - Dynamically patches its Caddyfile to add learning-resources routes for multiple service paths
   - Runs Caddy web server on port 8000 serving from `/srv/dist`
   - Handles routes: `/learning-resources/*`, `/settings/learning-resources/*`, `/openshift/learning-resources/*`, `/ansible/learning-resources/*`, `/insights/learning-resources/*`, `/edge/learning-resources/*`, `/iam/learning-resources/*`

### Volume Mounts

The e2e-task uses multiple volumes:

- **workdir**: EmptyDir volume (`/var/workdir`) shared between:
  - The Playwright test step
  - All three sidecars

- **chrome-dev-caddyfile**: ConfigMap volume mounted in insights-chrome-dev sidecar
  - Provides Caddy server configuration at `/etc/caddy/Caddyfile`
  - Defined inline at the top of `shared-e2e-pipeline.yaml`

- **proxy-config**: EmptyDir volume mounted in frontend-dev-proxy sidecar
  - Written dynamically by the `setup-proxy-routes` step
  - Contains routing configuration at `/config/routes`
  - Populated from the `PROXY_ROUTES` parameter (customizable per repository)

## Important Notes

### Minikube Disk Space

Minikube's default disk size (20GB) may be insufficient. The `cluster_setup/start.sh` script automatically starts Minikube with 40GB disk space:

```bash
minikube start --driver=podman --container-runtime=cri-o --disk-size=40g
```

If you need to manually reset Minikube:
```bash
minikube delete
./cluster_setup/start.sh
```

### Playwright Configuration

The Playwright step:
- Runs as root user (UID 0)
- Uses the image: `mcr.microsoft.com/playwright:v1.58.0-noble` (default)
  - Can be overridden via the `PLAYWRIGHT_IMAGE` parameter
  - A custom image with bind9 DNS utilities is available at `quay.io/btweed/playwright_e2e:latest`
  - Custom images can be built using `playwright_image/build_and_push.sh`
- Executes tests from `/workspace/output` (the cloned source)
- Has access to environment variables:
  - `HTTP_PROXY` / `HTTPS_PROXY`: Proxy configuration
  - `E2E_USER` / `E2E_PASSWORD`: Test authentication credentials
  - `NO_PROXY`: Excludes `stage.foo.redhat.com` from proxy
- Resource limits:
  - CPU: 2000m-4000m
  - Memory: 4Gi-8Gi

### Network Architecture

The test environment uses a multi-container setup with the following network flow:

```
Playwright Tests (using stage.foo.redhat.com)
    ↓
    (hostAliases redirect to 127.0.0.1:1337)
    ↓
frontend-dev-proxy:1337 (Caddy with custom routes)
    ↓
    ├─→ /apps/chrome* → 127.0.0.1:9912 (insights-chrome-dev Caddy)
    ├─→ /apps/learning-resources* → 127.0.0.1:8000 (run-application Caddy)
    ├─→ Other /learning-resources/* variants → 127.0.0.1:9912 (configurable via proxy-routes)
    └─→ Catch-all routes → https://${STAGE_ACTUAL_HOSTNAME} (via HTTP_PROXY to real stage)
```

Note: Routes are fully customizable via the `proxy-routes` parameter in Caddy directive format.

**Key architectural points:**

- Tests use `stage.foo.redhat.com` (configured in test code)
- `hostAliases` in PodSpec redirect `stage.foo.redhat.com` to `127.0.0.1` for all containers
- Frontend-dev-proxy serves TLS on port 1337 with certs for `stage.foo.redhat.com`
- All sidecars run in the same pod, allowing direct communication via `127.0.0.1`
- Frontend-dev-proxy performs environment variable substitution in its Caddyfile before starting
- Catch-all handler uses `STAGE_ACTUAL_HOSTNAME` (not in hostAliases) to reach the real stage environment through `HTTP_PROXY`

### Dynamic Configuration

The pipeline uses a dynamic configuration approach:

1. **Proxy Routes Configuration**: The `setup-proxy-routes` step (using busybox) writes the `PROXY_ROUTES` parameter to `/config/routes` before the sidecars start
2. **Repository-Specific Routes**: Each repository can customize routing in `repo-specific-pipelinerun.yaml` by overriding the `proxy-routes` parameter with Caddy directives
3. **Startup Synchronization**: The frontend-dev-proxy waits up to 60 seconds for the routes configuration file to be available before starting
4. **Environment Variable Substitution**: The frontend-dev-proxy performs environment variable substitution in its Caddyfile, replacing placeholders like `{$LOCAL_ROUTES}`, `{$HCC_ENV_URL}`, `{$HCC_ENV}`, and `{$STAGE_ACTUAL_HOSTNAME}`
5. **Readiness Checks**: The frontend-dev-proxy waits for both insights-chrome-dev (port 9912) and run-application (port 8000) to become ready before starting Caddy

### Image Pre-loading

To avoid potential rate limiting issues when pulling container images, you can pre-load images into Minikube:

1. The `cluster_setup/image_load.sh` script pre-loads critical images:
   - `quay.io/btweed/playwright_e2e:latest` (optional custom image with DNS utilities)
   - `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`
   - `busybox:latest`

2. Run this script after starting Minikube but before executing the pipeline:
   ```bash
   ./cluster_setup/image_load.sh
   ```

Note: You must be authenticated to Quay.io with podman for this script to work. The default Microsoft Playwright image (`mcr.microsoft.com/playwright:v1.58.0-noble`) will be pulled automatically and doesn't need pre-loading.

### Building Custom Playwright Image

To build and push a custom Playwright image:

1. Set your Quay.io username:
   ```bash
   export QUAY_USER="your-quay-username"
   ```

2. Build and push:
   ```bash
   cd playwright_image
   ./build_and_push.sh
   ```

This will build the image from `playwright_image/Dockerfile` and push it to `quay.io/$QUAY_USER/playwright_e2e:latest`.

## Customizing for Different Repositories

The pipeline is designed to be reusable across different repositories using a centralized configuration system.

### Adding a New Repository

1. **Create ConfigMaps in the external repository**:
   - Create Caddy ConfigMap files in the external ConfigMap repository (specified by `CONFIGMAP_REPO`)
   - Typically two ConfigMaps per repository:
     - `<repo-name>-dev-proxy-caddyfile`: Routes configuration for frontend-dev-proxy
     - `<repo-name>-test-app-caddyfile`: Caddy configuration for the application under test

2. **Create a PipelineRun YAML file**:
   - Copy an existing file from `pipelineruns/` (e.g., `frontend-starter-app.yaml`)
   - Save as `pipelineruns/<repo-name>.yaml`
   - Update the following fields:
     - `spec.params[].repo-url`: Git repository URL
     - `spec.params[].PROXY_ROUTES_CONFIGMAP`: Name of dev-proxy ConfigMap
     - `spec.params[].APP_CONFIG_CONFIGMAP`: Name of test-app ConfigMap
     - `spec.taskRunSpecs[].podTemplate.volumes[]`: ConfigMap volume mounts
   - Environment variables (`${BRANCH_NAME}`, `${SOURCE_ARTIFACT}`, etc.) will be substituted at runtime

3. **Add entry to `repos.yaml`**:
   ```yaml
   repositories:
     my-app:
       pipelinerun: my-app.yaml
       configmaps:
         - path: path/to/my-app-dev-proxy-caddyfile.yaml
         - path: path/to/my-app-test-app-caddyfile.yaml
   ```

4. **Run the pipeline**:
   ```bash
   export CONFIGMAP_REPO="git@gitlab.example.com:org/configmaps.git"
   export SOURCE_ARTIFACT="quay.io/org/my-app:tag"
   export BRANCH_NAME="main"
   # ... set other required environment variables

   ./run_pipeline.sh my-app
   ```

### Architecture Notes

- The `shared-e2e-pipeline.yaml` file remains unchanged and is shared across all repositories
- Repository-specific configuration lives in:
  - `repos.yaml`: Maps repository names to PipelineRun files and ConfigMap paths
  - `pipelineruns/<repo>.yaml`: Pre-generated PipelineRun templates with environment variable placeholders
  - External ConfigMap repository: Contains all Caddy configuration files
- The `run_pipeline.sh` script:
  - Uses `yq` to parse `repos.yaml`
  - Clones the external ConfigMap repository to `.configmaps-cache/`
  - Strips namespace metadata from ConfigMaps before applying to local cluster
  - Performs environment variable substitution on PipelineRun templates with `envsubst`
