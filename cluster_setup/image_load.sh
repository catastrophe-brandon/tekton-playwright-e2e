#!/usr/bin/env bash


# minikube has issues pulling the cypress image and some others due to excessive rate limiting by docker.io
# This script explicitly pulls them with podman and then loads them into minikube to sidestep docker's aggressive limitations
#
set -e

# If you are not logged into quay.io with podman, this will not work

podman pull quay.io/btweed/playwright_e2e:latest
minikube image load quay.io/btweed/playwright_e2e:latest

podman pull quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest
minikube image load quay.io/redhat-services-prod/hcc-platex-services-tenant/insights-chrome-dev:latest

podman pull busybox:latest
minikube image load busybox:latest

# TODO: add code to pull the minikube dashboard images and load them into the cluster

