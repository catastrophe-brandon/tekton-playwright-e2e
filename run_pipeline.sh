#!/usr/bin/env bash

if [ ! -n "${E2E_USER}" ]; then
	echo "Set E2E_USER"
	exit 1
fi

if [ ! -n "${E2E_PASSWORD}" ]; then
	echo "Set E2E_PASSWORD"
	exit 1
fi

if [ ! -n "${E2E_PROXY_URL}" ]; then
	echo "Set E2E_PROXY_URL"
	exit 1
fi

if [ ! -n "${STAGE_ACTUAL_HOSTNAME}" ]; then
	echo "Set STAGE_ACTUAL_HOSTNAME"
	exit 1
fi

if [ ! -n "${HTTP_PROXY}" ]; then
	echo "Set HTTP_PROXY"
	exit 1
fi

if [ ! -n "${HTTPS_PROXY}" ]; then
	echo "Set HTTPS_PROXY"
	exit 1
fi

echo "Clearing out previous run (if present)"
yes | tkn pipelinerun delete e2e-pipeline-run

sleep 10

set -e

echo "Applying shared E2E pipeline definition (ConfigMaps, Task, Pipeline)"
kubectl apply --filename shared-e2e-pipeline.yaml

echo "Generating repository-specific PipelineRun with Caddy configs"
cat <<EOF | kubectl apply --filename -
---
# Repository-specific PipelineRun configuration
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  name: e2e-pipeline-run
spec:
  params:
    - name: branch-name
      value: btweed/e2e
    - name: repo-url
      value: https://github.com/RedHatInsights/learning-resources.git
    - name: SOURCE_ARTIFACT
      value: quay.io/redhat-services-prod/hcc-platex-services-tenant/learning-resources:latest
    - name: E2E_USER
      value: "${E2E_USER}"
    - name: E2E_PASSWORD
      value: "${E2E_PASSWORD}"
    - name: e2e_proxy
      value: "${E2E_PROXY_URL}"
    - name: STAGE_ACTUAL_HOSTNAME
      value: "${STAGE_ACTUAL_HOSTNAME}"
    - name: HCC_ENV_URL
      value: "${HCC_ENV_URL:-https://console.stage.redhat.com}"
    - name: HCC_ENV
      value: "stage"
    - name: app-caddy-config
      value: |
$(cat caddy_config/app_config | while IFS= read -r line; do echo "        $line"; done)
    - name: proxy-routes
      value: |
$(cat caddy_config/proxy_config | while IFS= read -r line; do echo "        $line"; done)
  workspaces:
    - name: shared-code-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 2Gi
  pipelineRef:
    name: e2e-pipeline
  taskRunSpecs:
    - pipelineTaskName: e2e-test-run
      podTemplate:
        hostAliases:
          - ip: "::1"
            hostnames:
              - "stage.foo.redhat.com"
          - ip: "127.0.0.1"
            hostnames:
              - "stage.foo.redhat.com"
EOF

# View the logs of recent task runs
echo "Waiting for pods to spin up..."
sleep 6

echo "== PipelineRun Logs ==="
tkn pipelinerun logs -f

