#!/bin/bash
source ../script/deploy-cp-portal.sh
source ./fed-vars.sh

JOIN_MEMBER=false
for arg in "$@"; do
  case "$arg" in
    --join) JOIN_MEMBER=true ;;
  esac
done

deploy_federation_addons() {
  set_fed_config
  deploy_nats
}

set_fed_config() {
  local yaml_path="../values/cp-portal-fed-sa.yaml"

  # 1: Create namespace on host cluster
  kubectl create namespace "${NAMESPACE[4]}" --dry-run=client -o yaml | kubectl apply -f -

  # 2: Create kubeconfig secret using Karmada kubeconfig
  if ! sudo cat "$KARMADA_CONFIG_PATH" > /dev/null 2>&1; then
    echo "[ERROR] Cannot access KARMADA_CONFIG_PATH: $KARMADA_CONFIG_PATH"
    return 1
  fi

  sudo cat "$KARMADA_CONFIG_PATH" \
    | kubectl create secret generic kubeconfig \
        --from-file=kubeconfig=/dev/stdin \
        -n "${NAMESPACE[4]}" \
        --dry-run=client -o yaml \
    | kubectl apply -f -

  # 3: Apply federation SA to host cluster
  echo "▶ host"
  TG_NAMESPACE="${NAMESPACE[4]}" envsubst < "$yaml_path" | kubectl apply -f -

  # 4: Apply SA to karmada-apiserver and extract token
  echo "▶ karmada-apiserver"
  KARMADA_TOKEN=$(sudo cat "$KARMADA_CONFIG_PATH" | {
    tmpcfg=$(mktemp)
    trap 'rm -f "$tmpcfg"' EXIT
    cat > "$tmpcfg"

    TG_NAMESPACE="karmada-system" envsubst < "$yaml_path" \
      | kubectl --kubeconfig="$tmpcfg" apply -f - 1>&2

    for i in {1..10}; do
      token=$(kubectl --kubeconfig="$tmpcfg" -n karmada-system \
        get secret/cp-portal-federation-sa \
        -o go-template="{{.data.token | base64decode}}" 2>/dev/null)

      [ -n "$token" ] && echo "$token" && break
      sleep 1
    done
  })

  [ -z "$KARMADA_TOKEN" ] && echo "[ERROR] Failed to extract KARMADA_TOKEN." && return 1
}

deploy_nats() {
  local chart_path="../charts/${NATS_CHART_NAME}-${NATS_CHART_VERSION}.tgz"
  local values_path="../values/${NATS_CHART_NAME}.yaml"

  [ -f "$chart_path" ] || helm pull -d ../charts "$K_PAAS_HELM_OCI_REPO/$NATS_CHART_NAME" --version "$NATS_CHART_VERSION"

  find ../values -type f -exec sed -i "s/{NATS_ID}/$NATS_ID/g" {} +
  find ../values -type f -exec sed -i "s/{NATS_PASSWORD}/$NATS_PASSWORD/g" {} +

  helm install "$NATS_CHART_NAME" -f "$values_path" "$chart_path" -n ${NAMESPACE[4]}
}

main_cp_portal_fed() {
  local chart_path="../charts/${CHART_NAME[4]}-${CHART_VERSION[${CHART_NAME[4]}]}.tgz"

  helm install $RELEASE_NAME \
    -f ../values/cp-portal-fed.yaml \
    -f ../values/cp-portal-migration-secret.yaml \
    "$chart_path" \
    -n ${NAMESPACE[4]} \
    --set-string tlsSecret.tls.crt="$(base64 -w 0 < ../certs/${HOST_DOMAIN}.crt)" \
    --set-string tlsSecret.tls.key="$(base64 -w 0 < ../certs/${HOST_DOMAIN}.key)" \
    --set-string secret[0].data.CHART_REPO_CRT="$(base64 -w 0 < ../certs/ca.crt)" \
    --set-string secret[1].data.KARMADA_TOKEN="$KARMADA_TOKEN"

  terraman_ssh_key_copy
  # Uninstall cp-cert-setup
  helm uninstall "${CHART_NAME[7]}" -n "$CP_CERT_SETUP_NAMESPACE"
}

main_federation() {
  main_pre_cp_portal
  deploy_federation_addons
  main_cp_portal_fed

  if [ "$JOIN_MEMBER" = true ]; then
    echo "▶ Starting member cluster registration..."
    chmod +x ./join-members.sh
    if ! ./join-members.sh; then
      echo "[ERROR] Member cluster registration failed."
      exit 1
    fi
  fi
}

main_federation
