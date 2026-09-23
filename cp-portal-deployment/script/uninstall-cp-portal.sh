#!/bin/bash

source ../script/cp-portal-vars.sh

delete_chaos_mesh_crd() {
    CRDS=$(kubectl get crd -o custom-columns=NAME:.metadata.name,GROUP:.spec.group --no-headers | awk '$2 == "chaos-mesh.org" {print $1}')
    for crd in $CRDS; do
        kubectl get "$crd" -A --no-headers 2>/dev/null | awk '{print $1, $2}' | while read -r ns name; do
            has_finalizer=$(kubectl get "$crd" "$name" -n "$ns" -o jsonpath='{.metadata.finalizers}' 2>/dev/null)
            if [[ -n "$has_finalizer" && "$has_finalizer" != "[]" ]]; then
                kubectl patch "$crd" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
            fi
            kubectl delete "$crd" "$name" -n "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
        done

        kubectl delete crd "$crd" --wait=false --ignore-not-found
    done
}

main_uninstall_cp_portal() {
    # delete cluster-admin sa, clusterrolebinding
    kubectl delete sa $K8S_CLUSTER_ADMIN -n $K8S_CLUSTER_ADMIN_NAMESPACE
    kubectl delete clusterrolebinding $K8S_CLUSTER_ADMIN

    # uninstall chart and delete namespace
    for NAMESPACE in ${NAMESPACE[@]}; do
        PVS=$(kubectl get pvc -o jsonpath='{.items[*].spec.volumeName}' -n $NAMESPACE)
        helm uninstall $(helm ls --short -n $NAMESPACE) -n $NAMESPACE --no-hooks

        if [[ $NAMESPACE == "chaos-mesh" ]]; then
            delete_chaos_mesh_crd
        fi

        kubectl delete ns $NAMESPACE
        if [[ ${#PVS} -gt 0 ]]; then kubectl delete pv $PVS; fi
    done

    # uninstall cp-cert-setup
    helm uninstall ${CHART_NAME[7]} -n $CP_CERT_SETUP_NAMESPACE 2>/dev/null

    # remove helm repo and cm-push plugin
    helm repo remove $CHART_REPOSITORY_NAME
    helm plugin remove cm-push

    # remove host_domain cert
    sudo rm -rf /usr/local/share/ca-certificates/${HOST_DOMAIN}.crt
    sudo update-ca-certificates

    # delete directories
    sudo rm -r ../secmg
    sudo rm -r ../values
    sudo rm -r ../certs

    return 0
}

print_uninstall_summary() {
    echo
    echo "-----------------------------------------------------------------------------"
    echo "* kubectl get namespace"
    echo "-----------------------------------------------------------------------------"
    kubectl get namespace

    echo
    echo "-----------------------------------------------------------------------------"
    echo "* helm repo list"
    echo "-----------------------------------------------------------------------------"
    helm repo list

    echo
    echo "-----------------------------------------------------------------------------"
    echo "* helm list --all-namespaces"
    echo "-----------------------------------------------------------------------------"
    helm list --all-namespaces
    echo
}

confirm_uninstall() {
    if [[ "$SKIP_PORTAL_CONFIRM" != "true" ]]; then
        read -p "Are you sure you want to delete the container platform portal? <y/n> " prompt
        if [[ ! "$prompt" =~ ^(y|Y|yes|Yes)$ ]]; then
            echo "Cancelled."
            return 1
        fi
    fi
    return 0
}

main() {
    confirm_uninstall || return 1
    main_uninstall_cp_portal
    print_uninstall_summary
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main
