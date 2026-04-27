#!/bin/bash
# wait_for_kapp.sh

KUBECONFIG_PATH=$1
CRD_NAME="apps.kappctrl.k14s.io"

echo "⏳ Esperando a que el motor (kapp-controller) registre su CRD de Apps..."

for i in {1..20}; do
  if kubectl --kubeconfig "$KUBECONFIG_PATH" get crd "$CRD_NAME" >/dev/null 2>&1; then
    echo "✅ kapp-controller está listo para recibir el instalador de Educates."
    # Un pequeño respiro para que el API server asimile la nueva CRD
    sleep 5
    exit 0
  fi
  echo "  (Intento $i/20): kapp-controller aún inicializando..."
  sleep 5
done

echo "❌ Error: kapp-controller no registró su CRD a tiempo."
exit 1