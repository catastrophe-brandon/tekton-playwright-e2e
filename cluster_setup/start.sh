#!/usr/bin/env bash

set -e

# Only the pipeline needs these env vars. If they are set when we start minikube they can cause DNS resolution issues.
unset HTTP_PROXY
unset HTTPS_PROXY


# check status and start minikube if it's not running
# More disk space needed for running e2e tests, Tekton, etc.
minikube start --driver=podman --container-runtime=cri-o --disk-size=40g

minikube status
