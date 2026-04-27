#!/bin/bash
# wait_for_namespace.sh

KUBECONFIG_PATH=$1
NS_NAME=$2
MAX_RETRIES=30
RETRY_INTERVAL=5

echo "⏳ Waiting for namespace $NS_NAME to be created..."

for i in $(seq 1 $MAX_RETRIES); do
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get namespace "$NS_NAME" >/dev/null 2>&1; then
    echo "✅ Namespace $NS_NAME detected after $i attempts."
    exit 0
  fi
  echo "   (Attempt $i/$MAX_RETRIES): Not found yet. Retrying in ${RETRY_INTERVAL}s..."
  sleep $RETRY_INTERVAL
done

echo "❌ ERROR: The namespace $NS_NAME was not created in time by the operator."
exit 1