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
echo "Installing git-clone task from Tekton Hub..."
if ! tkn hub install task git-clone; then
    echo "Warning: Tekton Hub installation failed. Falling back to GitHub repository..."
    kubectl apply -f https://raw.githubusercontent.com/tektoncd/catalog/main/task/git-clone/0.9/git-clone.yaml
fi

# Verify the git-clone task was installed successfully
echo "Verifying git-clone task installation..."
if tkn task describe git-clone &> /dev/null; then
    echo "✓ git-clone task installed successfully!"
else
    echo "✗ Error: git-clone task installation failed!"
    exit 1
fi
