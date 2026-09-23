#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/rocky-linux.sh
source "$SCRIPT_DIR/../lib/rocky-linux.sh"
require_rocky_linux_9_7 || exit 1
source cp-portal-vars-mc.sh

function delete_namespace() {
   local -n indexs=$1
   for i in ${indexs[*]}
   do
     PVS=$($CMD_KCTL get pvc -o jsonpath='{.items[*].spec.volumeName}' -n ${NAMESPACE[$i]})
     $CMD_HELM uninstall $($CMD_HELM ls --short -n ${NAMESPACE[$i]}) -n ${NAMESPACE[$i]} --no-hooks
     if [[ ${NAMESPACE[$i]} == "chaos-mesh" ]]; then
        delete_chaos_mesh_crd
     fi
     $CMD_KCTL delete ns ${NAMESPACE[$i]}
     if [[ ${#PVS} -gt 0 ]]; then $CMD_KCTL delete pv $PVS; fi
   done
}
function delete_chaos_mesh_crd(){
   CRDS=$($CMD_KCTL get crd -o custom-columns=NAME:.metadata.name,GROUP:.spec.group --no-headers | awk '$2 == "chaos-mesh.org" {print $1}')
   for crd in $CRDS; do
     $CMD_KCTL get "$crd" -A --no-headers 2>/dev/null | awk '{print $1, $2}' | while read -r ns name; do
       has_finalizer=$($CMD_KCTL get "$crd" "$name" -n "$ns" -o jsonpath='{.metadata.finalizers}' 2>/dev/null)
       if [[ -n "$has_finalizer" && "$has_finalizer" != "[]" ]]; then
         $CMD_KCTL patch "$crd" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
       fi
       $CMD_KCTL delete "$crd" "$name" -n "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
     done
     $CMD_KCTL delete crd "$crd" --wait=false --ignore-not-found
   done
}
#######
read -p "Are you sure you want to delete the container platform portal? <y/n> " prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]
then

  CMD_KCTL_ORIG="kubectl --context={TG_CTX}"
  CMD_HELM_ORIG="helm --kube-context={TG_CTX}"

  # remove host_domain cert
  remove_host_ca "${HOST_DOMAIN}.crt"

  for IDX in 1 2; do
    echo "[Remove resources in cluster${IDX}]..."
    TARGET_CTX="CLUSTER${IDX}_CONFIG[CTX]"
    CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
    CMD_HELM=$(echo "$CMD_HELM_ORIG" | sed "s/{TG_CTX}/${!TARGET_CTX}/")
    # delete cluster-admin sa, clusterrolebinding
    $CMD_KCTL delete sa $K8S_CLUSTER_ADMIN -n $K8S_CLUSTER_ADMIN_NAMESPACE
    $CMD_KCTL delete clusterrolebinding $K8S_CLUSTER_ADMIN
    # uninstall cp-cert-setup resource
    $CMD_HELM uninstall ${CHART_NAME[7]} -n $CP_CERT_SETUP_NAMESPACE 2> /dev/null
    # uninstall chart and delete namespace
    if [ ${IDX} -eq 1 ]
    then
      # delete resources in istio-system
      $CMD_HELM uninstall $ISTIO_RESOURCE_NAME -n $ISTIO_NAMESPACE
      # delete mariadb
      $CMD_KCTL delete ns ${NAMESPACE[1]}
      # uninstall chart and delete namespace
      TARGET_NS_IDX=(0 2 3 4 5 6)
      delete_namespace TARGET_NS_IDX
      # remove helm repo and cm-push plugin
      $CMD_HELM repo remove $CHART_REPOSITORY_NAME
      $CMD_HELM plugin remove cm-push
    else
      # delete secrets management
      $CMD_KCTL delete ns ${NAMESPACE[0]}
      # uninstall chart and delete namespace
      TARGET_NS_IDX=(1 4)
      delete_namespace TARGET_NS_IDX
    fi

      echo
      echo "-----------------------------------------------------------------------------"
      echo "* kubectl get namespace"
      echo "-----------------------------------------------------------------------------"
      $CMD_KCTL get namespace
      echo
      echo "-----------------------------------------------------------------------------"
      echo "* helm repo list"
      echo "-----------------------------------------------------------------------------"
      $CMD_HELM repo list
      echo
      echo "-----------------------------------------------------------------------------"
      echo "* helm list --all-namespaces"
      echo "-----------------------------------------------------------------------------"
      $CMD_HELM list --all-namespaces
      echo
      echo
  done

  # delete dir
  sudo rm -r ../secmg
  sudo rm -r ../values
  sudo rm -r ../certs
else
  exit 0
fi
