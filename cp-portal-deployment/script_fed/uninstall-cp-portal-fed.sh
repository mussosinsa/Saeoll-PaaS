#!/bin/bash
source ../script/uninstall-cp-portal.sh
source ./fed-vars.sh

YAML_PATH="../values_orig/cp-portal-fed-sa.yaml"

delete_fed_yaml_from_karmada() {
    echo "▶ karmada-apiserver"
    local TMP_CFG
    TMP_CFG=$(mktemp)
    trap 'rm -f "$TMP_CFG"' EXIT

    sudo cat "$KARMADA_CONFIG_PATH" > "$TMP_CFG" 2>/dev/null || {
        echo "[ERROR] Cannot load Karmada kubeconfig: $KARMADA_CONFIG_PATH"
        return 1
    }

    TG_NAMESPACE="karmada-system" envsubst < "$YAML_PATH" | \
        kubectl --kubeconfig="$TMP_CFG" delete -f - --ignore-not-found
}

delete_fed_yaml_from_host() {
    echo "▶ host"
    TG_NAMESPACE="${NAMESPACE[4]}" envsubst < "$YAML_PATH" | \
        kubectl delete -f - --ignore-not-found
}

main_uninstall_fed() {
    confirm_uninstall || exit 0
    delete_fed_yaml_from_karmada
    delete_fed_yaml_from_host
    export SKIP_PORTAL_CONFIRM=true
    main_uninstall_cp_portal
    print_uninstall_summary
}

main_uninstall_fed