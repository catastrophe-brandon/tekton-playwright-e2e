#!/usr/bin/env bash

set -ex
 
# Sets up forwarding to the dev proxy for use with local browser
kubectl port-forward e2e-pipeline-run-e2e-test-run-pod 1337:1337 &


