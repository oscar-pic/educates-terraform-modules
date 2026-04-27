terraform state rm $(terraform state list | grep -E 'kubernetes_|kubectl_|time_sleep|data.kubernetes_namespace|kapp|kubeconfig|tls|wait_for_k8s')
# 1. Borra el despliegue del controlador (esto debería matar el Pod zombi)
kubectl --kubeconfig ./k8s_config.yaml delete deployment kapp-controller -n kapp-controller --force --grace-period=0

# 1. Quitar finalizers de las Apps de Carvel (lo más probable es que sea esto)
kubectl --kubeconfig ./k8s_config.yaml get apps -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml replace --raw "/apis/kappctrl.k14s.io/v1alpha1/namespaces/educates-installer/apps" -f -

# 2. Quitar finalizers de PackageInstalls (si los hay)
kubectl --kubeconfig ./k8s_config.yaml get packageinstalls -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml replace --raw "/apis/packaging.carvel.dev/v1alpha1/namespaces/educates-installer/packageinstalls" -f -

# 3. Si sigue vivo, prueba a parchear los CustomResourceDefinitions (CRDs) que suelen bloquear
for crd in $(kubectl --kubeconfig ./k8s_config.yaml get crd | grep "educates\|k14s\|carvel" | awk '{print $1}'); do
    kubectl --kubeconfig ./k8s_config.yaml patch crd $crd -p '{"metadata":{"finalizers":[]}}' --type=merge
done
# 2. Borra el Namespace de la forma más violenta posible (vía API directa)
kubectl --kubeconfig ./k8s_config.yaml patch ns kapp-controller -p '{"spec":{"finalizers":null}}' --type=merge

# 1. Quitar finalizers de todos los recursos de Educates (Portales, Sesiones, Workshops)
for resource in trainingportals workshops workshoprequests workshopsessions; do
  echo "Limpiando finalizers de: $resource"
  kubectl --kubeconfig ./k8s_config.yaml get $resource -n educates -o json 2>/dev/null | \
  jq '.items[].metadata.finalizers = []' | \
  kubectl --kubeconfig ./k8s_config.yaml apply -f - 2>/dev/null
done

# Quitar finalizadores de todas las Apps
kubectl --kubeconfig ./k8s_config.yaml get apps -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml apply -f -

# Quitar finalizadores de todos los PackageInstalls
kubectl --kubeconfig ./k8s_config.yaml get packageinstalls -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml apply -f -

# Quitar finalizadores de PackageRepositories
kubectl --kubeconfig ./k8s_config.yaml get packagerepositories -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml apply -f -

# Quitar finalizadores de metadatos de paquetes
kubectl --kubeconfig ./k8s_config.yaml get internalpackagemetadatas.internal.packaging.carvel.dev -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml apply -f -

# Quitar finalizadores de versiones de paquetes
kubectl --kubeconfig ./k8s_config.yaml get packages.packaging.carvel.dev -A -o json | jq '.items[].metadata.finalizers = []' | kubectl --kubeconfig ./k8s_config.yaml apply -f -

kubectl --kubeconfig ./k8s_config.yaml get ns kapp-controller-packaging-global -o json | jq '.spec.finalizers = []' > temp_global.json
kubectl --kubeconfig ./k8s_config.yaml replace --raw "/api/v1/namespaces/kapp-controller-packaging-global/finalize" -f temp_global.json
rm temp_global.json

# 2. Atacar a los MutatingWebhooks (A veces bloquean el borrado de recursos internos)
kubectl --kubeconfig ./k8s_config.yaml delete mutatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found
kubectl --kubeconfig ./k8s_config.yaml delete validatingwebhookconfiguration -l app.kubernetes.io/part-of=educates --ignore-not-found

# 3. El parche de gracia al namespace educates
kubectl --kubeconfig ./k8s_config.yaml get ns educates -o json | jq '.spec.finalizers = []' > temp_ns.json
kubectl --kubeconfig ./k8s_config.yaml replace --raw "/api/v1/namespaces/educates/finalize" -f temp_ns.json
rm temp_ns.json
for ns in educates-installer educates-ui educates kapp-controller kapp-controller-packaging-global kyverno; do
  echo "Limpiando namespace: $ns"
  # 1. Quitamos los finalizers del objeto namespace
  kubectl --kubeconfig ./k8s_config.yaml get namespace $ns -o json 2>/dev/null | jq '.spec.finalizers = []' > temp.json
  kubectl --kubeconfig ./k8s_config.yaml replace --raw "/api/v1/namespaces/$ns/finalize" -f temp.json 2>/dev/null

  # 2. Forzamos el borrado
  kubectl --kubeconfig ./k8s_config.yaml delete ns $ns --force --grace-period=0 2>/dev/null
done
rm temp.json
# 1. Borra los APIServices (Esto es lo que suele colgar los comandos de kubectl)
kubectl --kubeconfig ./k8s_config.yaml delete apiservice v1alpha1.data.packaging.carvel.dev v1alpha1.packaging.carvel.dev 2>/dev/null

# 2. Borra el despliegue del controlador (esto matará los pods de kapp-controller)
kubectl --kubeconfig ./k8s_config.yaml delete deployment kapp-controller -n kapp-controller 2>/dev/null
kubectl --kubeconfig ./k8s_config.yaml delete ns kapp-controller --force --grace-period=0 2>/dev/null

# 3. Borra el secreto que te dio error de "already exists"
kubectl --kubeconfig ./k8s_config.yaml delete secret educates-wildcard-certs -n educates-ui 2>/dev/null
# Borramos los servicios de API de Carvel/Educates que suelen quedarse colgados
kubectl --kubeconfig ./k8s_config.yaml delete apiservice v1alpha1.data.packaging.carvel.dev 2>/dev/null
kubectl --kubeconfig ./k8s_config.yaml delete apiservice v1alpha1.packaging.carvel.dev 2>/dev/null
kubectl --kubeconfig ./k8s_config.yaml delete crd $(kubectl --kubeconfig ./k8s_config.yaml get crd | grep educates.dev | awk '{print $1}')
kubectl --kubeconfig ./k8s_config.yaml delete crd $(kubectl --kubeconfig ./k8s_config.yaml get crd | grep carvel.dev | awk '{print $1}')
kubectl --kubeconfig ./k8s_config.yaml delete crd $(kubectl --kubeconfig ./k8s_config.yaml get crd | grep kyverno | awk '{print $1}')
# Quitar finalizers y borrar la CRD de un tirón
kubectl --kubeconfig ./k8s_config.yaml patch crd apps.kappctrl.k14s.io -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl --kubeconfig ./k8s_config.yaml delete crd apps.kappctrl.k14s.io --force --grace-period=0
kubectl --kubeconfig ./k8s_config.yaml get crds -A | egrep -iv "traefik|networking|cattle"
# 1. Borra el secreto y el service account conflictivos
kubectl --kubeconfig ./k8s_config.yaml delete secret educates-installer-config -n educates-installer 2>/dev/null
kubectl --kubeconfig ./k8s_config.yaml delete sa educates-installer -n educates-installer 2>/dev/null

# 2. Borra el binding que probablemente también de error después
kubectl --kubeconfig ./k8s_config.yaml delete clusterrolebinding educates-installer-admin-binding 2>/dev/null

# Borra todos los pods en namespaces que no deberían existir
kubectl --kubeconfig ./k8s_config.yaml delete pod --all -n kapp-controller --force --grace-period=0
kubectl --kubeconfig ./k8s_config.yaml delete pod --all -n kyverno --force --grace-period=0

# Borra el secreto que dice que "ya existe"
kubectl --kubeconfig ./k8s_config.yaml delete secret educates-wildcard-certs -n educates-ui

# Borra el intento de portal si es que existe algo
kubectl --kubeconfig ./k8s_config.yaml delete trainingportal educates -n educates-ui 2>/dev/null
# Reinicia el servicio de K3s en tu nodo de Proxmox
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.1.29 "sudo systemctl restart k3s"
