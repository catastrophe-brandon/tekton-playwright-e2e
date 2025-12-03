#!/usr/bin/env bash

# Install Tekton and required tasks to execute the pipeline
# Requires tkn cli and kubectl
set -e

# Install Tekton to an existing minikube instance
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

echo "Waiting for Tekton controller to be ready..."
kubectl wait --for=condition=ready pod -l app=tekton-pipelines-controller -n tekton-pipelines --timeout=120s

echo "Waiting for Tekton webhook to be ready..."
kubectl wait --for=condition=ready pod -l app=tekton-pipelines-webhook -n tekton-pipelines --timeout=120s

echo "Tekton installation complete and ready!"

# Install the git-clone task for use in the pipeline
tkn hub install task git-clone
