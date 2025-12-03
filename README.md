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
- envsubst

### Getting Started

1. **Set environment variables**:
   ```bash
   export E2E_USER="your-test-username"
   export E2E_PASSWORD="your-test-password"
   export E2E_PROXY_URL="your-proxy-url"
   export STAGE_ACTUAL_HOSTNAME="actual-stage-hostname.example.com"
   export HCC_ENV_URL="https://actual.stage.redhat.com"
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

5. **Run the E2E pipeline**:
   ```bash
   ./run_pipeline.sh
   ```

The pipeline will:
- Validate required environment variables
- Clean up previous pipeline/task runs
- Apply the shared E2E pipeline definition
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
│   ├── Dockerfile                    # Playwright v1.50.0 + bind9 utilities
│   └── build_and_push.sh             # Build and push to Quay.io
│
├── helper_scripts/                   # Helper scripts for local testing
│   ├── browse_locally.sh             # Open browser to local proxy
│   └── forward.sh                    # Port forward from pod to localhost
│
├── shared-e2e-pipeline.yaml          # Shared Tekton definitions
│                                     # (ConfigMap, Task, Pipeline)
│
├── repo-specific-pipelinerun.yaml    # Repository-specific PipelineRun
│                                     # with custom proxy routes
│
└── run_pipeline.sh                   # Execute the E2E pipeline
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

### Pipeline Parameters

The pipeline is configured through two files:

**`shared-e2e-pipeline.yaml`** (shared across all repositories):
- Contains the Caddy ConfigMap for insights-chrome-dev
- Defines the e2e-task with sidecars
- Defines the e2e-pipeline

**`repo-specific-pipelinerun.yaml`** (repository-specific):
- `branch-name`: Git branch to test
- `repo-url`: Repository URL containing E2E tests
- `SOURCE_ARTIFACT`: Container image with the application build
- `proxy-routes`: Custom proxy routes configuration (Caddy directives format)
- Optional overrides: `PLAYWRIGHT_IMAGE`, `CHROME_DEV_IMAGE`, `PROXY_IMAGE`, `APP_PORT`, `e2e-tests-script`

### Environment Variables

Required environment variables (used by `run_pipeline.sh` for substitution):
- `E2E_USER`: Test user credentials
- `E2E_PASSWORD`: Test user password
- `E2E_PROXY_URL`: Proxy server URL
- `STAGE_ACTUAL_HOSTNAME`: Actual stage environment hostname (bypasses hostAliases)
- `HCC_ENV_URL`: HCC environment URL for proxy configuration

## Customization

### Adapting for Different Repositories

The pipeline is designed to be reusable. To customize for a new repository:

1. **Copy and edit `repo-specific-pipelinerun.yaml`**:
   - Update `branch-name` and `repo-url` to point to your repository
   - Update `SOURCE_ARTIFACT` to point to your application image
   - Customize `proxy-routes` with Caddy directives for your routing needs
   - Set environment variables: `E2E_USER`, `E2E_PASSWORD`, `E2E_PROXY_URL`, `STAGE_ACTUAL_HOSTNAME`, `HCC_ENV_URL`

2. **Optional overrides**:
   - Override `PLAYWRIGHT_IMAGE`, `CHROME_DEV_IMAGE`, or `PROXY_IMAGE` for custom images
   - Override `APP_PORT` if your application uses a different port
   - Override `e2e-tests-script` to run custom test commands

3. **Apply the pipeline**:
   ```bash
   ./run_pipeline.sh
   ```

The `shared-e2e-pipeline.yaml` file remains unchanged and can be shared across all repositories.

### Building Custom Playwright Image

```bash
export QUAY_USER="your-quay-username"
cd playwright_image
./build_and_push.sh
```

Update the `PLAYWRIGHT_IMAGE` parameter in your `repo-specific-pipelinerun.yaml` to reference the custom image.

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