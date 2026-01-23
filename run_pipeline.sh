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

echo "Applying shared E2E pipeline definition (Task, Pipeline)"
kubectl apply --filename shared-e2e-pipeline.yaml

echo "Applying repository-specific ConfigMaps"
kubectl apply --filename frontend-starter-app-dev-proxy-caddyfile.yaml
kubectl apply --filename frontend-starter-app-test-app-caddyfile.yaml

echo "Applying repository-specific PipelineRun"
envsubst < repo-specific-pipelinerun.yaml | kubectl apply --filename -

# View the logs of recent task runs
echo "Waiting for pods to spin up..."
sleep 6

echo "== PipelineRun Logs ==="
tkn pipelinerun logs -f

