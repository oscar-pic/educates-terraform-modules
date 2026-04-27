#!/bin/bash
# wait_for_kapp.sh

KUBECONFIG_PATH=$1
CRD_NAME="apps.kappctrl.k14s.io"

echo "⏳ Waiting for kapp-controller to register its Apps CRD..."

for i in {1..20}; do
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "✅ kapp-controller is ready to receive the Educates installer."
    # A little pause for the API server to assimilate the new CRD
    sleep 5
    exit 0
  fi
  echo "  (Attempt $i/20): kapp-controller still initializing..."
  sleep 5
done

echo "❌ Error: kapp-controller did not register its CRD in time."
exit 1