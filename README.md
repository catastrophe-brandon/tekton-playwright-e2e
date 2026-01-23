# Tekton Playwright E2E Testing

A local Tekton pipeline environment for running E2E Playwright tests using Minikube.

## Purpose

This project provides a reusable local testing environment that mirrors production deployment patterns. It uses Tekton pipelines to orchestrate:

- **Source cloning** from application test repositories
- **Application deployment** using containerized builds
- **E2E test execution** with Playwright in an isolated environment
- **Proxy and asset serving** to simulate production dependencies

The pipeline is designed to be reusable across different repositories, with shared pipeline definitions and repository-specific customizations for routing and configuration.

## Quick Start

### Prerequisites

- Minikube
- Podman
- kubectl
- tkn (Tekton CLI)
- yq (install with `brew install yq`)
- envsubst

### Getting Started

1. **Set environment variables**:
   ```bash
   # ConfigMap repository (contains Caddy config for all apps)
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

2. **Initialize Minikube cluster**:
   ```bash
   ./cluster_setup/start.sh
   ```

3. **Install Tekton**:
   ```bash
   ./cluster_setup/install_tekton.sh
   ```

4. **(Optional) Pre-load images** to avoid Docker Hub rate limiting:
   ```bash
   ./cluster_setup/image_load.sh
   ```

5. **Run the E2E pipeline** for a specific repository:
   ```bash
   ./run_pipeline.sh frontend-starter-app
   # or
   ./run_pipeline.sh learning-resources
   ```

The pipeline will:
- Parse `repos.yaml` to extract configuration for the specified repository
- Validate required environment variables
- Clone/update the external ConfigMap repository to `.configmaps-cache/`
- Apply ConfigMaps (with namespace stripped) to current namespace
- Apply the shared E2E pipeline definition (Task, Pipeline)
- Apply the repository-specific PipelineRun with environment variable substitution
- Clone the source, deploy the application with sidecars, and execute Playwright tests

## Project Structure

```
tekton-playwright/
├── cluster_setup/                    # Minikube and Tekton initialization
│   ├── start.sh                      # Start Minikube (40GB disk, cri-o)
│   ├── install_tekton.sh             # Install Tekton and git-clone task
│   └── image_load.sh                 # Pre-load images to avoid rate limits
│
├── playwright_image/                 # Custom Playwright test image
│   ├── Dockerfile                    # Playwright v1.58.0 + bind9 utilities
│   └── build_and_push.sh             # Build and push to Quay.io
│
├── helper_scripts/                   # Helper scripts for local testing
│   ├── browse_locally.sh             # Open browser to local proxy
│   └── forward.sh                    # Port forward from pod to localhost
│
├── pipelineruns/                     # Pre-generated PipelineRun templates
│   ├── frontend-starter-app.yaml     # PipelineRun for frontend-starter-app
│   ├── learning-resources.yaml       # PipelineRun for learning-resources
│   └── README.md                     # Documentation for adding new repos
│
├── repos.yaml                        # Central repository configuration
│                                     # Maps repos to ConfigMaps and PipelineRuns
│
├── shared-e2e-pipeline.yaml          # Shared Tekton definitions
│                                     # (ConfigMap, Task, Pipeline)
│
└── run_pipeline.sh                   # Execute pipeline for specified repo
```

## Architecture

The E2E pipeline orchestrates a multi-container testing environment with dynamic routing:

```
Playwright Tests (using stage.foo.redhat.com)
    ↓
    (hostAliases redirect to 127.0.0.1:1337)
    ↓
frontend-dev-proxy:1337 (Caddy with custom routes)
    ↓
    ├─→ /apps/chrome* → 127.0.0.1:9912 (insights-chrome-dev)
    ├─→ /apps/learning-resources* → 127.0.0.1:8000 (run-application)
    ├─→ Custom routes (via proxy-routes) → configurable
    └─→ Catch-all → https://${STAGE_ACTUAL_HOSTNAME} (via HTTP_PROXY)
```

### Key Architectural Features

- Tests use `stage.foo.redhat.com` (configured in test code)
- `hostAliases` redirect `stage.foo.redhat.com` to `127.0.0.1` for all containers
- Frontend-dev-proxy serves TLS on port 1337 with certs for `stage.foo.redhat.com`
- All sidecars run in the same pod, allowing direct communication via `127.0.0.1`
- Catch-all handler uses `STAGE_ACTUAL_HOSTNAME` to reach real stage through `HTTP_PROXY`

### Pipeline Stages

1. **fetch-source**: Clones the test repository using Tekton's git-clone task
2. **e2e-test-run**: Executes the e2e-task which includes:
   - **setup-proxy-routes** step: Writes custom proxy routes from `proxy-routes` parameter
   - **Playwright tests** step: Runs E2E tests from the cloned source
   - **Three sidecars**:
     - `frontend-dev-proxy`: Routes requests using custom Caddy directives (port 1337)
     - `insights-chrome-dev`: Serves chrome UI static assets via Caddy (port 9912)
     - `run-application`: Runs the application under test from `SOURCE_ARTIFACT` image (port 8000)

## Configuration

### Pipeline Configuration

The pipeline uses a multi-file configuration system:

**`repos.yaml`** (central configuration):
- Maps repository names to PipelineRun files
- Specifies ConfigMap paths in the external repository
- Example: `./run_pipeline.sh frontend-starter-app` → uses `pipelineruns/frontend-starter-app.yaml`

**`pipelineruns/<repo>.yaml`** (repository-specific PipelineRuns):
- `branch-name`: Git branch to test (substituted from `$BRANCH_NAME`)
- `repo-url`: Repository URL containing E2E tests
- `SOURCE_ARTIFACT`: Container image with the application build (substituted from `$SOURCE_ARTIFACT`)
- ConfigMap names for dev-proxy and test-app configurations
- Optional overrides: `PLAYWRIGHT_IMAGE`, `CHROME_DEV_IMAGE`, `PROXY_IMAGE`, `APP_PORT`, `e2e-tests-script`

**`shared-e2e-pipeline.yaml`** (shared across all repositories):
- Contains the Caddy ConfigMap for insights-chrome-dev
- Defines the e2e-task with sidecars
- Defines the e2e-pipeline

**External ConfigMap Repository** (specified by `$CONFIGMAP_REPO`):
- Contains Caddy configuration files for all applications
- ConfigMaps are fetched at runtime and applied to local namespace

### Environment Variables

**ConfigMap Repository** (required):
- `CONFIGMAP_REPO`: Git repository URL containing ConfigMaps
- `CONFIGMAP_BRANCH`: Branch to clone from (optional, defaults to `main`)

**Test Credentials & Proxy** (required):
- `E2E_USER`: Test user credentials
- `E2E_PASSWORD`: Test user password
- `E2E_PROXY_URL`: Proxy server URL
- `HTTP_PROXY`: HTTP proxy
- `HTTPS_PROXY`: HTTPS proxy
- `STAGE_ACTUAL_HOSTNAME`: Actual stage environment hostname (bypasses hostAliases)
- `HCC_ENV_URL`: HCC environment URL for proxy configuration

**Repository-Specific** (required):
- `SOURCE_ARTIFACT`: Container image to test

**Optional** (with defaults):
- `BRANCH_NAME`: Git branch to test (default: `main`)
- `HCC_ENV`: Environment name (default: `stage`)

## Customization

### Adding a New Repository

The pipeline uses a centralized multi-repository system. To add a new repository:

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

The `shared-e2e-pipeline.yaml` file remains unchanged and is shared across all repositories.

See [pipelineruns/README.md](pipelineruns/README.md) for detailed instructions.

### Building Custom Playwright Image

```bash
export QUAY_USER="your-quay-username"
cd playwright_image
./build_and_push.sh
```

Update the `PLAYWRIGHT_IMAGE` parameter in your `pipelineruns/<repo>.yaml` to reference the custom image.

## Troubleshooting

### Insufficient Disk Space

The `start.sh` script allocates 40GB by default. To increase:
```bash
minikube delete
minikube start --driver=podman --container-runtime=cri-o --disk-size=60g
```

### Docker Hub Rate Limiting

Run `./cluster_setup/image_load.sh` to pre-load images from Quay.io:
- `quay.io/btweed/playwright_e2e:latest`
- `quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest`
- `busybox:latest`

Note: You must be authenticated to Quay.io with podman for this script to work.

### Viewing Pipeline Logs

```bash
tkn pipelinerun logs -f
```

### Checking Pod Status

```bash
kubectl get pods
kubectl describe pod <pod-name>
```

### Debugging Proxy Routes

The frontend-dev-proxy sidecar includes:
- Debug mode enabled by default
- Admin API on port 2019
- Custom routes written to `/config/routes` from `proxy-routes` parameter
- Environment variable substitution: `{$LOCAL_ROUTES}`, `{$HCC_ENV_URL}`, `{$STAGE_ACTUAL_HOSTNAME}`

## Advanced Details

For comprehensive documentation including:
- Volume mounts and workspace configuration
- Resource limits and Playwright configuration
- Network architecture and DNS setup
- Dynamic configuration and startup synchronization
- Sidecar-specific details

See [.claude/claude.md](.claude/claude.md).

## License

This project is for internal testing purposes.