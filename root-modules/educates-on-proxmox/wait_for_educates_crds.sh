#!/bin/bash
# wait_for_crds.sh

KUBECONFIG_PATH=$1
CRD_NAME="trainingportals.training.educates.dev"

echo "⏳ Waiting for Educates CRDs to be registered..."

for i in {1..30}; do
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "✅ CRDs detected. Waiting 20s extra for stabilization..."
    sleep 20
    exit 0
  fi
  echo "  (Attempt $i/30): CRDs still not found. Retrying in 10s..."
  sleep 10
done

echo "❌ Error: Timeout waiting for CRDs."
exit 1