#!/bin/bash

# Configuration
KUBECFG="--kubeconfig ./k8s_config.yaml"
NAMESPACES=("educates" "educates-installer" "educates-ui" "kapp-controller" "kapp-controller-packaging-global" "kyverno")
CONTROL_NODE_IP="192.168.1.29"

echo "--- 0. CLEANING TERRAFORM STATE ---"
TERRAFORM_RESOURCES=$(terraform state list | grep -E 'kubernetes_|kubectl_|time_sleep|data.kubernetes_namespace|kapp|kubeconfig|tls|wait_for_k8s|wait_for_educates_crds|null_resource')
if [ ! -z "$TERRAFORM_RESOURCES" ]; then
    echo "Removing Kubernetes resources from Terraform state..."
    terraform state rm $TERRAFORM_RESOURCES > /dev/null
fi

echo "--- 1. PREVENTIVE POD DELETION ---"
kubectl $KUBECFG delete pods --all -A --force --grace-period=0 2>/dev/null

echo "--- 2. REMOVING EDUCATES RESOURCES & FINALIZERS ---"
RESOURCES=("trainingportals" "workshops" "workshoprequests" "workshopsessions")
for res in "${RESOURCES[@]}"; do
    echo "Cleaning $res..."
    kubectl $KUBECFG get $res -A -o json 2>/dev/null | jq -r '.items[].metadata.name' | xargs -I {} kubectl $KUBECFG patch $res {} -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
    kubectl $KUBECFG delete $res --all --force --grace-period=0 2>/dev/null
done

echo "--- 3. REMOVING CARVEL APPS & PACKAGES ---"
CARVEL_RES=("apps.kappctrl.k14s.io" "packageinstalls.packaging.carvel.dev" "packagerepositories.packaging.carvel.dev")
for res in "${CARVEL_RES[@]}"; do
    echo "Processing $res..."
    # Get the list of resources with their namespaces and names
    RESOURCES_DATA=$(kubectl $KUBECFG get $res -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')
    
    if [ ! -z "$RESOURCES_DATA" ]; then
        echo "$RESOURCES_DATA" | while read -r ns name; do
            if [ ! -z "$name" ] && [ "$name" != "null" ]; then
                echo "  -> Killing finalizers for $name in $ns..."
                # 1. Delete finalizers from metadata and spec (some K8s require spec.finalizers to be empty [])
                kubectl $KUBECFG patch $res $name -n $ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
                # 2. Delete the resource forcefully in the background
                kubectl $KUBECFG delete $res $name -n $ns --force --grace-period=0 --timeout=5s >/dev/null 2>&1 &
            fi
        done
    fi
done
# Give a moment for background deletions to be processed
sleep 2

echo "--- 4. CLEANING WEBHOOKS & API SERVICES ---"
# These often block namespace deletion if the service they point to is gone
kubectl $KUBECFG delete mutatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete validatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl $KUBECFG delete apiservice v1alpha1.data.packaging.carvel.dev v1alpha1.packaging.carvel.dev 2>/dev/null

echo "--- 5. CLEANING ORPHAN SECRETS AND SAs AND CLEANING GLOBAL RESOURCES ---"
# Delete remaining resources that Terraform has indicated already exist
kubectl $KUBECFG -n educates-installer delete secret educates-wildcard-certs educates-installer-config --ignore-not-found
kubectl $KUBECFG -n educates-installer delete sa educates-installer --ignore-not-found
kubectl $KUBECFG delete clusterrolebinding educates-installer-admin-binding --ignore-not-found

# Limpiar el secreto (si por alguna razón el NS no se lo llevó)
kubectl $KUBECFG -n educates-installer delete secret educates-wildcard-certs --ignore-not-found

echo "--- 6. PREVENTIVE KYVERNO CLEANUP ---"
# 1. Desactivamos los webhooks para que no bloqueen los borrados
kubectl $KUBECFG delete mutatingwebhookconfiguration -l app.kubernetes.io/part-of=kyverno --ignore-not-found
kubectl $KUBECFG delete validatingwebhookconfiguration -l app.kubernetes.io/part-of=kyverno --ignore-not-found

# 2. Borramos el namespace con parcheo inmediato de finalizadores
kubectl $KUBECFG delete ns kyverno --force --grace-period=0 2>/dev/null &
sleep 2
kubectl $KUBECFG patch ns kyverno -p '{"metadata":{"finalizers":null},"spec":{"finalizers":null}}' --type=merge 2>/dev/null

echo "--- 7. FORCING NAMESPACE TERMINATION (PRO VERSION) ---"
for ns in "${NAMESPACES[@]}"; do
    if kubectl $KUBECFG get namespace $ns >/dev/null 2>&1; then
        echo "Processing namespace: $ns"
        
        # ELIMINACIÓN DE FINALIZADORES EN METADATA Y SPEC
        kubectl $KUBECFG patch namespace $ns -p '{"metadata":{"finalizers":null},"spec":{"finalizers":null}}' --type=merge 2>/dev/null
        
        # Intento de borrado normal pero rápido
        kubectl $KUBECFG delete ns $ns --force --grace-period=0 --timeout=5s > /dev/null 2>&1

        if kubectl $KUBECFG get namespace $ns >/dev/null 2>&1; then
            echo "  -> Namespace $ns still stuck. Executing API Finalize..."
            PORT=$((10000 + RANDOM % 5000))
            kubectl $KUBECFG proxy --port=$PORT > /dev/null 2>&1 &
            PROXY_PID=$!
            sleep 2

            # Generamos el JSON de finalización vacío
            # Nota: Algunos K8s necesitan que el spec.finalizers esté vacío []
            kubectl $KUBECFG get namespace $ns -o json | jq '.spec.finalizers = []' > "temp_ns.json"
            
            curl -s -X PUT "http://127.0.0.1:$PORT/api/v1/namespaces/$ns/finalize" \
                 -H "Content-Type: application/json" \
                 --data-binary @temp_ns.json > /dev/null
            
            kill -9 $PROXY_PID 2>/dev/null
            rm "temp_ns.json" 2>/dev/null
            
            # Verificación final: si sigue ahí, parcheamos el objeto crudo (último recurso)
            kubectl $KUBECFG patch namespace $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
            echo "  -> Namespace $ns finalized via API."
        fi
    fi
done

echo "--- 8. DELETING ALL RELATED CRDS (ULTRA-AGGRESSIVE) ---"
# Obtain the list of CRDs that match our patterns (educates, k14s, carvel, kyverno)
CRDS=$(kubectl $KUBECFG get crd -o json 2>/dev/null | jq -r '.items[].metadata.name | select(test("educates|k14s|carvel|kyverno"))')

if [ ! -z "$CRDS" ]; then
    for crd in $CRDS; do
        echo "  -> Killing CRD: $crd"
        
        # 1. Force the finalizer removal using a JSON patch (more reliable than merge for arrays)
        # this eliminates any "anchor" the CRD has with the system, allowing it to be deleted even if it's in a weird state
        kubectl $KUBECFG patch crd "$crd" --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null
        
        # 2. If the above fails (e.g., if the finalizers field doesn't exist), we fallback to a merge patch that sets it to an empty array
        kubectl $KUBECFG patch crd "$crd" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
        
        # 3. Launch the deletion in the background with a timeout to prevent hanging indefinitely
        kubectl $KUBECFG delete crd "$crd" --force --grace-period=0 --timeout=2s >/dev/null 2>&1 &
    done
fi

# 4. Verification final quick check: if any survive, we patch them directly by name
echo "  -> Final sweep for stubborn CRDs..."
REBELS=("secretcopiers.secrets.educates.dev" "secretinjectors.secrets.educates.dev")
for r in "${REBELS[@]}"; do
    kubectl $KUBECFG patch crd "$r" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
done

echo "   (CRD cleanup background tasks triggered)"
sleep 2

echo "--- 9. REFRESHING K3S SERVICES ---"
# Assume that the user is 'ubuntu' and the IP is your control node's IP

echo "Restarting K3s on $CONTROL_NODE_IP to clear auth caches..."
ssh -o StrictHostKeyChecking=no ubuntu@$CONTROL_NODE_IP "sudo systemctl restart k3s"

echo "Waiting 20s for API Server to be healthy again..."
sleep 20

echo "--- 10. FINAL STATUS REPORT ---"
echo "Active Pods:"
kubectl $KUBECFG get pods -A
echo ""
echo "Active Namespaces:"
kubectl $KUBECFG get namespaces
echo ""
echo "Remaining Terraform State:"
terraform state list
echo ""
echo "Clean up complete. The state should now only contain Proxmox/VM resources."