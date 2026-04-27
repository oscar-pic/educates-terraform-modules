#!/bin/bash
KUBECFG="--kubeconfig ./k8s_config.yaml"

# Borrar pods a la fuerza antes de tocar los namespaces
echo "Matando pods de forma preventiva..."
kubectl $KUBECFG delete pods --all -A --force --grace-period=0 2>/dev/null

# Si después de borrar el NS el pod sigue ahí (como ahora),
# este comando intentará borrarlo ignorando la existencia del NS en el API
kubectl $KUBECFG delete pod kapp-controller-799564ccbb-wpj6k -n kapp-controller --force --grace-period=0 2>/dev/null

echo "--- 0. BORRADO DE ESTADOS DE TERRAFORM ---"
terraform state rm $(terraform state list | grep -E 'kubernetes_|kubectl_|time_sleep|data.kubernetes_namespace|kapp|kubeconfig|tls|wait_for_k8s|wait_for_educates_crds')

echo "--- 1. BORRANDO RECURSOS DE EDUCATES (CON FINALIZERS) ---"
for res in trainingportals workshops workshoprequests workshopsessions; do
    kubectl $KUBECFG get $res -A -o json 2>/dev/null | jq -r '.items[].metadata.name' | xargs -I {} kubectl $KUBECFG patch $res {} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
    kubectl $KUBECFG delete $res --all --force --grace-period=0 2>/dev/null
done

echo "--- 2. BORRANDO APPS Y PAQUETES DE CARVEL ---"
for res in apps packageinstalls packagerepositories; do
    kubectl $KUBECFG patch $res --all -A -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
    kubectl $KUBECFG delete $res --all -A --force --grace-period=0 2>/dev/null
done

echo "--- 3. ELIMINANDO WEBHOOKS Y SERVICIOS DE API ---"
kubectl $KUBECFG delete mutatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete validatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete apiservice v1alpha1.data.packaging.carvel.dev v1alpha1.packaging.carvel.dev 2>/dev/null

echo "--- 4. ELIMINANDO TODOS LOS CRDS DE EDUCATES/CARVEL ---"
# Esto es lo que realmente mata a los controladores y sus pods
kubectl $KUBECFG delete crd $(kubectl $KUBECFG get crd | grep -E "educates|k14s|carvel|kyverno" | awk '{print $1}') --force --grace-period=0 2>/dev/null

echo "--- 5. LIMPIANDO PERMISOS GLOBALES (CLUSTERROLES) ---"
kubectl $KUBECFG delete clusterrolebinding -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete clusterrole -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete clusterrolebinding educates-installer-admin-binding 2>/dev/null

echo "--- 6. ANIQUILANDO NAMESPACES (VÍA API FINALIZE) ---"
for ns in educates educates-installer educates-ui kapp-controller kapp-controller-packaging-global kyverno; do
    echo "Forzando cierre de: $ns"
    kubectl $KUBECFG get namespace $ns -o json 2>/dev/null | jq '.spec.finalizers = []' > temp_ns.json
    kubectl $KUBECFG replace --raw "/api/v1/namespaces/$ns/finalize" -f temp_ns.json 2>/dev/null
    kubectl $KUBECFG delete ns $ns --force --grace-period=0 2>/dev/null
done
rm temp_ns.json 2>/dev/null
# Bucle para limpiar namespaces rebeldes
for ns in educates educates-installer educates-ui kapp-controller kapp-controller-packaging-global kyverno; do
  if kubectl $KUBECFG get namespace $ns >/dev/null 2>&1; then
    echo "Forzando limpieza profunda de: $ns"

    # 1. Quitar finalizadores de todos los recursos del namespace
    kubectl $KUBECFG delete all --all -n $ns --force --grace-period=0 2>/dev/null

    # 2. El truco del proxy para el finalize
    kubectl $KUBECFG get namespace $ns -o json | jq '.spec.finalizers = []' > temp_ns.json

    # Lanzamos proxy en puerto aleatorio para evitar conflictos
    PORT=8001
    kubectl $KUBECFG proxy --port=$PORT &
    PROXY_PID=$!
    sleep 2

    curl -s -X PUT http://127.0.0.1:$PORT/api/v1/namespaces/$ns/finalize \
         -H "Content-Type: application/json" --data-binary @temp_ns.json > /dev/null

    kill $PROXY_PID 2>/dev/null
    rm temp_ns.json
  fi
done

echo "--- 7. VERIFICACIÓN FINAL ---"
kubectl $KUBECFG get pods -A
terraform state list
