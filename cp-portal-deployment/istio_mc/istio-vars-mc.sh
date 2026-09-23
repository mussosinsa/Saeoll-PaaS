#!/bin/bash
# command line tool
KUBECTL_VERSION="1.33.4"
HELM_VERSION="3.18.4"
STEP_VERSION="0.24.4"

# Istio
ISTIO_VERSION="1.28.0"
ISTIO_NAMESPACE="istio-system"

# get all the contexts in kubeconfig
export CLUSTER_CNT=$((kubectl config get-contexts | tail -n +2 | cut -c9- | wc -l) 2>/dev/null)
for IDX in $(seq 1 "$CLUSTER_CNT"); do
  eval "declare -A CLUSTER${IDX}_CONFIG"

  CTX=$(kubectl config get-contexts | tail -n +2 | cut -c9- | awk -v cnt="$IDX" 'NR==cnt {print $1}')
  CLUSTER=$(kubectl config get-contexts | tail -n +2 | cut -c9- | awk -v cnt="$IDX" 'NR==cnt {print $2}')

  eval "CLUSTER${IDX}_CONFIG[CTX]=\"$CTX\""
  eval "CLUSTER${IDX}_CONFIG[CLUSTER]=\"$CLUSTER\""
  eval "CLUSTER${IDX}_CONFIG[NETWORK]=\"network${IDX}\""
done