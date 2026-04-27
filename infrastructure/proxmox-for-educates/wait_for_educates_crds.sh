#!/bin/bash
# wait_for_crds.sh

KUBECONFIG_PATH=$1
CRD_NAME="trainingportals.training.educates.dev"

echo "⏳ Esperando a que el operador de Educates registre las CRDs..."

for i in {1..30}; do
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "✅ CRDs detectadas. Esperando 20s extra para estabilización..."
    sleep 20
    exit 0
  fi
  echo "  (Intento $i/30): CRDs aún no encontradas. Reintentando en 10s..."
  sleep 10
done

echo "❌ Error: Tiempo de espera agotado para las CRDs."
exit 1