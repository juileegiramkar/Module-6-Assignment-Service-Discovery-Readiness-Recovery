#!/usr/bin/env bash
# Remove everything the lab created (all objects live in the inventory-lab namespace).
set -euo pipefail
kubectl delete namespace inventory-lab --ignore-not-found --wait=true
