#!/bin/bash
source istio-vars-mc.sh
CMD_ISTIOCTL_ORIG="istioctl --context={TG_CTX}"
CMD_KCTL_ORIG="kubectl --context={TG_CTX}"

read -p "Are you sure you want to uninstall istio in all clusters? <y/n> " prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]
then
  # Uninstall Istio in clusters
  for IDX in $(seq 1 "$CLUSTER_CNT"); do
    echo "[Uninstall Istio in cluster${IDX}]..."
    TG_CTX="CLUSTER${IDX}_CONFIG[CTX]"
    CMD_ISTIOCTL=$(echo "$CMD_ISTIOCTL_ORIG" | sed "s/{TG_CTX}/${!TG_CTX}/")
    CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TG_CTX}/")
    $CMD_ISTIOCTL uninstall -y --purge
    $CMD_KCTL kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.8.0" | $CMD_KCTL delete -f -;
    $CMD_KCTL delete ns $ISTIO_NAMESPACE
  done
  # Remove dirs
  rm -r certs
  rm -r resource
else
  exit 0
fi