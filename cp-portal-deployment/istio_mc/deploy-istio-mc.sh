#!/bin/bash
source istio-vars-mc.sh
CMD_ISTIOCTL_ORIG="istioctl --context={TG_CTX}"
CMD_KCTL_ORIG="kubectl --context={TG_CTX}"

# Creating dirs
mkdir certs
mkdir resource

# Generate Root CA
echo "[Generate Root CA]..."
step certificate create root.istio.io certs/root-cert.pem certs/root-ca.key \
  --profile root-ca --no-password --insecure --san root.istio.io \
  --not-after 87600h --kty RSA

for IDX in $(seq 1 "$CLUSTER_CNT"); do
  echo "[Install Istio in cluster${IDX}]..."
  TG_CTX="CLUSTER${IDX}_CONFIG[CTX]"
  TG_CLUSTER_NAME="CLUSTER${IDX}_CONFIG[CLUSTER]"
  TG_NETWORK="CLUSTER${IDX}_CONFIG[NETWORK]"
  CMD_ISTIOCTL=$(echo "$CMD_ISTIOCTL_ORIG" | sed "s/{TG_CTX}/${!TG_CTX}/")
  CMD_KCTL=$(echo "$CMD_KCTL_ORIG" | sed "s/{TG_CTX}/${!TG_CTX}/")

  mkdir -p certs/${!TG_CLUSTER_NAME}
  mkdir -p resource/${!TG_CLUSTER_NAME}

  cp -r resource_orig/* resource/${!TG_CLUSTER_NAME}
  find resource/${!TG_CLUSTER_NAME} -name "*.yaml" -exec sed -i "s/{ISTIO_NAMESPACE}/$ISTIO_NAMESPACE/g" {} \;
  find resource/${!TG_CLUSTER_NAME} -name "*.yaml" -exec sed -i "s/{TG_CLUSTER_NAME}/${!TG_CLUSTER_NAME}/g" {} \;
  find resource/${!TG_CLUSTER_NAME} -name "*.yaml" -exec sed -i "s/{TG_NETWORK}/${!TG_NETWORK}/g" {} \;

  step certificate create ${!TG_CLUSTER_NAME}.intermediate.istio.io certs/${!TG_CLUSTER_NAME}/ca-cert.pem certs/${!TG_CLUSTER_NAME}/ca-key.pem \
       --ca certs/root-cert.pem --ca-key certs/root-ca.key --profile intermediate-ca \
       --not-after 87600h --no-password --insecure --san ${!TG_CLUSTER_NAME}.intermediate.istio.io --kty RSA
  cat certs/${!TG_CLUSTER_NAME}/ca-cert.pem certs/root-cert.pem > certs/${!TG_CLUSTER_NAME}/cert-chain.pem

  $CMD_KCTL apply -f resource/${!TG_CLUSTER_NAME}/namespace.yaml
  $CMD_KCTL create secret generic cacerts -n $ISTIO_NAMESPACE \
          --from-file=certs/${!TG_CLUSTER_NAME}/ca-cert.pem \
          --from-file=certs/${!TG_CLUSTER_NAME}/ca-key.pem \
          --from-file=certs/${!TG_CLUSTER_NAME}/cert-chain.pem \
          --from-file=certs/root-cert.pem --dry-run=client -o yaml > resource/${!TG_CLUSTER_NAME}/certs.yaml
  $CMD_KCTL apply -f resource/${!TG_CLUSTER_NAME}/certs.yaml -n $ISTIO_NAMESPACE
  $CMD_ISTIOCTL install -y -f resource/${!TG_CLUSTER_NAME}/controlplane.yaml
  $CMD_ISTIOCTL install -y -f resource/${!TG_CLUSTER_NAME}/ingressgateway.yaml
  $CMD_KCTL apply -f resource/${!TG_CLUSTER_NAME}/expose-services.yaml -n $ISTIO_NAMESPACE
  $CMD_KCTL get crd gateways.gateway.networking.k8s.io &> /dev/null || \
    { $CMD_KCTL kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v0.8.0" | $CMD_KCTL apply -f -; }
done

for IDX in $(seq 1 "$CLUSTER_CNT"); do
  for IDX2 in $(seq 1 "$CLUSTER_CNT"); do
    if [[ "$IDX" -ne "$IDX2" ]]; then
      eval CTX=\${CLUSTER${IDX}_CONFIG[CTX]}
      eval CLUSTER_NAME=\${CLUSTER${IDX}_CONFIG[CLUSTER]}
      eval NEXT_CTX=\${CLUSTER${IDX2}_CONFIG[CTX]}

      istioctl create-remote-secret --context="$CTX" --name="$CLUSTER_NAME" | kubectl apply -f - --context="$NEXT_CTX"
    fi
  done
done

for IDX in $(seq 1 "$CLUSTER_CNT"); do
  echo
  echo "--------------------------------------------------------------"
  eval "echo \"[cluster${IDX} (\${CLUSTER${IDX}_CONFIG[CTX]})] $ istioctl remote-clusters\""
  echo "--------------------------------------------------------------"
  eval "istioctl remote-clusters --context=\"\${CLUSTER${IDX}_CONFIG[CTX]}\""
done