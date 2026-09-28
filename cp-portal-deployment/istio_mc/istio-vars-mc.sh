#!/bin/bash
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tool-versions.sh
source "$SCRIPT_DIR/tool-versions.sh"

# Istio
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
