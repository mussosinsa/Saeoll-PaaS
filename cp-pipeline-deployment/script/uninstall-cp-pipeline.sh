#!/bin/bash

source cp-pipeline-vars.sh

read -p "Are you sure you want to delete the container platform pipeline? <y/n> " prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]
then
  # uninstall chart and delete namespace
  PVS=$(kubectl get pvc -o jsonpath='{.items[*].spec.volumeName}' -n $NAMESPACE)
  helm uninstall $(helm ls --short -n $NAMESPACE) -n $NAMESPACE
  kubectl delete ns $NAMESPACE
  if [[ ${#PVS} -gt 0 ]]; then kubectl delete pv $PVS; fi
  if [[ "$IS_MULTI_CLUSTER" == "Y" ]] ; then helm uninstall $ISTIO_RESOURCE_NAME -n $ISTIO_NAMESPACE; fi
  rm -r ../values
  echo
  echo "-----------------------------------------------------------------------------"
  echo "* kubectl get ns"
  echo "-----------------------------------------------------------------------------"
  kubectl get ns
  echo
  echo "-----------------------------------------------------------------------------"
  echo "* helm list --all-namespaces"
  echo "-----------------------------------------------------------------------------"
  helm list --all-namespaces
  echo
  echo "-----------------------------------------------------------------------------"
  echo "* helm repo list"
  echo "-----------------------------------------------------------------------------"
  helm repo list
  echo
  echo
  echo
else
  exit 0
fi