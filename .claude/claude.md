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
- `repo-specific-pipelinerun.yaml`: PipelineRun instance with repository-specific parameters and custom proxy routes

### Cluster Setup Scripts (`cluster_setup/`)
- `start.sh`: Initializes Minikube with podman driver (40GB disk, cri-o runtime)
- `install_tekton.sh`: Installs Tekton pipelines and git-clone task from Tekton Hub
- `image_load.sh`: Pre-loads container images into Minikube to avoid Docker Hub rate limiting

### Playwright Image (`playwright_image/`)
- `Dockerfile`: Defines the Playwright test image (based on mcr.microsoft.com/playwright:v1.50.0-noble with bind9 utilities)
- `build_and_push.sh`: Script to build and push the Playwright image to Quay.io

### Execution Scripts
- `run_pipeline.sh`: Validates environment variables, applies shared pipeline definition, and follows logs
- `browse_locally.sh`: Helper script for local browsing
- `forward.sh`: Port forwarding helper script

## Prerequisites

- Minikube
- Podman (used as minikube driver)
- kubectl
- tkn (Tekton CLI)
- envsubst (for environment variable substitution in pipeline runs)

## Getting Started

1. Set required environment variables:
   ```bash
   export E2E_USER="your-test-username"
   export E2E_PASSWORD="your-test-password"
   export E2E_PROXY_URL="your-proxy-url"
   export STAGE_ACTUAL_HOSTNAME="actual-stage-hostname.example.com"
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

5. Run the E2E pipeline:
   ```bash
   ./run_pipeline.sh
   ```

   This script will:
   - Validate required environment variables (E2E_USER, E2E_PASSWORD, E2E_PROXY_URL, STAGE_ACTUAL_HOSTNAME)
   - Clean up previous pipeline/task runs
   - Apply the shared E2E pipeline definition (ConfigMaps, Task, Pipeline)
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
- `proxy-routes-json`: Custom proxy routes configuration (JSON format)
- `e2e-tests-script`: Custom test execution script (optional override)

### Workspaces

- `shared-code-workspace`: PersistentVolumeClaim (2Gi) that persists cloned source code between pipeline tasks
  - Mounted at `/workspace/output` in the git-clone task and e2e-task
  - Uses `volumeClaimTemplate` for automatic PVC creation

### Sidecars Configuration

The e2e-task runs three sidecars alongside the Playwright test step:

1. **frontend-dev-proxy**: Proxies requests to external resources
   - Image: `quay.io/redhat-user-workloads/hcc-platex-services-tenant/frontend-development-proxy:latest`
   - Custom routes defined in `/config/routes.json` (written dynamically from `PROXY_ROUTES_JSON` parameter)
   - Routes `/apps/chrome*` to `http://localhost:9912` with chrome HTML fallback enabled
   - Waits for route configuration to be written before starting

2. **insights-chrome-dev**: Serves chrome UI static assets
   - Image: `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`
   - Runs Caddy web server on port 9912
   - Configuration in `/etc/caddy/Caddyfile` (mounted from ConfigMap in `shared-e2e-pipeline.yaml`)
   - Serves files from `/opt/app-root/src/build/stable`
   - CORS enabled for cross-origin access

3. **run-application**: Runs the application under test
   - Image: Specified by `SOURCE_ARTIFACT` parameter
   - Contains the application to be tested

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
  - Contains routing configuration at `/config/routes.json`
  - Populated from the `PROXY_ROUTES_JSON` parameter (customizable per repository)

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
- Uses the image: `quay.io/btweed/playwright_e2e:latest`
  - Based on `mcr.microsoft.com/playwright:v1.50.0-noble`
  - Includes bind9 DNS utilities for network diagnostics
  - Can be rebuilt using `playwright_image/build_and_push.sh`
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
frontend-dev-proxy (Caddy routes)
    ↓
    ├─→ /apps/chrome* → localhost:9912 (insights-chrome-dev Caddy)
    ├─→ /learning-resources* → localhost:8000 (run-application)
    └─→ Other routes → https://${STAGE_ACTUAL_HOSTNAME} (via HTTP_PROXY to real stage)
```

**Key architectural points:**

- Tests use `stage.foo.redhat.com` (configured in test code)
- `hostAliases` in PodSpec redirect `stage.foo.redhat.com` to `127.0.0.1` for all containers
- Frontend-dev-proxy serves TLS on port 1337 with certs for `stage.foo.redhat.com`
- `localhost` in handle routes allows communication with sidecars in the same pod
- Catch-all handler uses `STAGE_ACTUAL_HOSTNAME` (not in hostAliases) to reach the real stage environment through `HTTP_PROXY`

### Dynamic Configuration

The pipeline uses a dynamic configuration approach:

1. **Proxy Routes Configuration**: The `setup-proxy-routes` step (using busybox) writes the `PROXY_ROUTES_JSON` parameter to `/config/routes.json` before the sidecars start
2. **Repository-Specific Routes**: Each repository can customize routing in `repo-specific-pipelinerun.yaml` by overriding the `proxy-routes-json` parameter
3. **Startup Synchronization**: The frontend-dev-proxy waits up to 60 seconds for the routes configuration file to be available before starting

### Docker Hub Rate Limiting

Docker Hub imposes aggressive rate limiting on image pulls. To avoid issues:

1. The `cluster_setup/image_load.sh` script pre-loads critical images:
   - `quay.io/btweed/playwright_e2e:latest`
   - `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`

2. Run this script after starting Minikube but before executing the pipeline:
   ```bash
   ./cluster_setup/image_load.sh
   ```

Note: You must be authenticated to Quay.io with podman for this script to work.

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

The pipeline is designed to be reusable across different repositories. To customize for a new repository:

1. **Copy and edit `repo-specific-pipelinerun.yaml`**:
   - Update `branch-name` and `repo-url` to point to your repository
   - Update `SOURCE_ARTIFACT` to point to your application image
   - Customize `proxy-routes-json` to match your application's routing needs

2. **Optional: Override the test script**:
   - Uncomment and customize the `e2e-tests-script` parameter to run custom test commands
   - Default script runs `npm install` and `npx playwright test`

3. **Apply the pipeline**:
   ```bash
   ./run_pipeline.sh
   ```

The `shared-e2e-pipeline.yaml` file remains unchanged and can be shared across all repositories.
