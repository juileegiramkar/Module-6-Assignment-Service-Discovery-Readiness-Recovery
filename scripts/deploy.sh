#!/usr/bin/env bash
# Build both images and deploy everything to the current kubectl context.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -t inventory-service:1.0 inventory
docker build -t inventory-client:1.0 client

# Inventory first, so the client finds Ready Pods behind the Service from its first request.
kubectl apply -f k8s/00-namespace.yaml -f k8s/10-inventory-deployment.yaml -f k8s/20-inventory-service.yaml
kubectl -n inventory-lab rollout status deployment/inventory --timeout=120s
kubectl apply -f k8s/30-client-deployment.yaml
kubectl -n inventory-lab rollout status deployment/inventory-client --timeout=120s
kubectl -n inventory-lab get deploy,pods,svc -o wide
