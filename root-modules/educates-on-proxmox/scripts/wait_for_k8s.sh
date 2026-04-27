#!/bin/bash
# wait_k8s.sh

KEY=$1
USER=$2
IP=$3
CONFIG=$4

# CLEANUP PREVENTIVE: Deleting any trace of the previous config
# to force the new SCP to be the one that takes precedence.
rm -f "$CONFIG"

# 1. Fetch and patch
scp -o StrictHostKeyChecking=no -q -i "$KEY" "$USER@$IP":/etc/rancher/k3s/k3s.yaml "$CONFIG"
sed "s|127.0.0.1|$IP|g" "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"

echo "------------------------------------------------------------"
echo "✔ Kubeconfig retrieved and patched for $IP"
echo "⏳ Waiting for Cluster to initialize pods..."

MAX_RETRIES=30
COUNT=0

while true; do
  # Counting the total number of pods
  TOTAL_PODS=$(KUBECONFIG="$CONFIG" kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)
  
  # Counting the number of pods that are not in Running or Completed state
  NOT_READY=$(KUBECONFIG="$CONFIG" kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l)

  # Logic: There must be at least 1 pod AND 0 pods that are not ready
  if [ "$TOTAL_PODS" -gt 0 ] && [ "$NOT_READY" -eq 0 ]; then
    echo "🚀 System pods are RUNNING ($TOTAL_PODS pods detected)!"
    break
  fi

  echo "Status: Total=$TOTAL_PODS, Waiting=$NOT_READY... retrying in 10s ($((COUNT+1))/$MAX_RETRIES)"
  sleep 10
  COUNT=$((COUNT+1))

  if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Timeout waiting for system pods"
    exit 1
  fi
done

echo "⏳ Final 30s for RBAC stabilization..."
sleep 30
echo "------------------------------------------------------------"