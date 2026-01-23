# PipelineRun Definitions

This directory contains pre-generated PipelineRun YAML files for each supported repository.

## Adding a New Repository

To add support for a new repository:

### 1. Create a PipelineRun YAML file

Create a new file in this directory (e.g., `my-app.yaml`) based on the template below:

```yaml
---
# PipelineRun configuration for my-app repository
# Environment variables will be substituted at runtime using envsubst
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: e2e-pipeline-run
spec:
  params:
    # Git repository configuration
    - name: branch-name
      value: ${BRANCH_NAME:-main}
    - name: repo-url
      value: https://github.com/YourOrg/my-app.git

    # Application artifact to test
    - name: SOURCE_ARTIFACT
      value: ${SOURCE_ARTIFACT}

    # Test credentials (substituted from environment variables)
    - name: E2E_USER
      value: "${E2E_USER}"
    - name: E2E_PASSWORD
      value: "${E2E_PASSWORD}"
    - name: e2e_proxy
      value: "${E2E_PROXY_URL}"
    - name: STAGE_ACTUAL_HOSTNAME
      value: "${STAGE_ACTUAL_HOSTNAME}"
    - name: HCC_ENV_URL
      value: "${HCC_ENV_URL}"
    - name: HCC_ENV
      value: "${HCC_ENV:-stage}"

    # ConfigMap names for Caddy configuration
    - name: PROXY_ROUTES_CONFIGMAP
      value: "my-app-dev-proxy-caddyfile"
    - name: APP_CONFIG_CONFIGMAP
      value: "my-app-test-app-caddyfile"

  # Workspace configuration
  workspaces:
    - name: shared-code-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi

  # Reference to the shared pipeline definition
  pipelineRef:
    name: e2e-pipeline

  # Task-specific runtime configuration
  taskRunSpecs:
    - pipelineTaskName: e2e-test-run
      podTemplate:
        # Override /etc/hosts to redirect stage.foo.redhat.com to localhost
        hostAliases:
          - ip: "::1"
            hostnames:
              - "stage.foo.redhat.com"
          - ip: "127.0.0.1"
            hostnames:
              - "stage.foo.redhat.com"
        # Override volumes to mount ConfigMaps
        volumes:
          - name: proxy-config
            configMap:
              name: my-app-dev-proxy-caddyfile
          - name: app-config
            configMap:
              name: my-app-test-app-caddyfile
```

### 2. Update repos.yaml

Add an entry in the root `repos.yaml` file:

```yaml
repositories:
  my-app:
    pipelinerun: my-app.yaml
    configmaps:
      - path: my-app/dev-proxy-caddyfile.yaml
      - path: my-app/test-app-caddyfile.yaml
```

### 3. Create ConfigMaps in external repository

Ensure the ConfigMap files exist in the external ConfigMap repository at the paths specified in `repos.yaml`.

### 4. Run the pipeline

```bash
export CONFIGMAP_REPO=git@gitlab.example.com:org/configmaps.git
export SOURCE_ARTIFACT=quay.io/org/my-app:latest
export HCC_ENV_URL=https://your-environment-url
# ... set other required environment variables

./run_pipeline.sh my-app
```

## Environment Variables

The following environment variables are required:

### ConfigMap Repository
- `CONFIGMAP_REPO`: Git repository URL containing ConfigMaps (required)
- `CONFIGMAP_BRANCH`: Branch to clone from (optional, defaults to `main`)

### Pipeline Parameters (substituted in PipelineRun files)
- `SOURCE_ARTIFACT`: Container image to test
- `E2E_USER`: Test user credentials
- `E2E_PASSWORD`: Test user password
- `E2E_PROXY_URL`: HTTP proxy URL
- `STAGE_ACTUAL_HOSTNAME`: Actual hostname for the stage environment
- `HCC_ENV_URL`: Environment URL
- `HTTP_PROXY`: HTTP proxy
- `HTTPS_PROXY`: HTTPS proxy

### Optional (with defaults)
- `BRANCH_NAME`: Git branch to test (default: `main`)
- `HCC_ENV`: Environment name (default: `stage`)

## ConfigMap Names

The ConfigMap names in your PipelineRun YAML must match the names defined in the ConfigMap YAML files in the external repository. The standard naming convention is:

- `<repo-name>-dev-proxy-caddyfile`: Routes configuration for the frontend-dev-proxy
- `<repo-name>-test-app-caddyfile`: Caddy configuration for the application under test
