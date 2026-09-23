#!/bin/bash

echo "▶ Member Cluster Configuration Generator"

########################################
# Step 1: Ask number of clusters (1~10)
########################################
while true; do
  read -p "How many member clusters do you want to register? (1-10): " MEMBER_COUNT

  if [[ "$MEMBER_COUNT" =~ ^[0-9]+$ ]] && [ "$MEMBER_COUNT" -ge 1 ] && [ "$MEMBER_COUNT" -le 10 ]; then
    break
  else
    echo "Invalid number. Please enter a number between 1 and 10."
  fi
done

echo ""
echo "You selected $MEMBER_COUNT member cluster(s)."
echo ""

########################################
# Step 2: Read available contexts
########################################
ALL_CONTEXTS=($(kubectl config get-contexts -o name))

if [ ${#ALL_CONTEXTS[@]} -eq 0 ]; then
  echo "No kubectl contexts found. Exiting."
  exit 1
fi

########################################
# Step 3: Prepare output file
########################################
OUTPUT_FILE="member-cluster-config.sh"
> "$OUTPUT_FILE"

cat <<EOF >> "$OUTPUT_FILE"
# Auto-generated member cluster config
# Edit API_SERVER or NAME if needed, and fill IAAS_TYPE manually.

EOF

########################################
# Step 4: Select contexts
########################################
AVAILABLE_CONTEXTS=("${ALL_CONTEXTS[@]}")

for ((i=1; i<=MEMBER_COUNT; i++)); do
  echo "▶ Select context for cluster $i"

  index=1
  for ctx in "${AVAILABLE_CONTEXTS[@]}"; do
    echo "  $index) $ctx"
    index=$((index+1))
  done

  while true; do
    read -p "Enter the number of the context for cluster $i: " ctx_number

    if [[ "$ctx_number" =~ ^[0-9]+$ ]] \
      && [ "$ctx_number" -ge 1 ] \
      && [ "$ctx_number" -le ${#AVAILABLE_CONTEXTS[@]} ]; then
      break
    else
      echo "Invalid selection. Try again."
    fi
  done

  SELECTED_CTX=${AVAILABLE_CONTEXTS[$((ctx_number-1))]}

  # Extract cluster name from context
  CLUSTER_NAME=$(kubectl config view \
    -o jsonpath="{.contexts[?(@.name=='$SELECTED_CTX')].context.cluster}")

  # Extract API server
  API_SERVER=$(kubectl config view \
    -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}")

  echo "Selected context       : $SELECTED_CTX"
  echo "Cluster name in config : $CLUSTER_NAME"
  echo "Detected API server    : $API_SERVER"
  echo ""

  # Write config lines
  {
    echo "# Cluster $i"
    echo "CLUSTER${i}_CTX=\"$SELECTED_CTX\""
    echo "CLUSTER${i}_API_SERVER=\"$API_SERVER\"   # Auto-detected. Change if using a different endpoint."
    echo "CLUSTER${i}_NAME=\"$CLUSTER_NAME\"       # Auto-detected. Change if naming differs from your env."
    echo "CLUSTER${i}_IAAS_TYPE=\"\"               # Fill manually (1 OPENSTACK, 2 NAVER, 3 NHN, 4 KT)"
    echo ""
  } >> "$OUTPUT_FILE"

  # Remove selected context
  new_list=()
  for ((j=0; j<${#AVAILABLE_CONTEXTS[@]}; j++)); do
    if [ $j -ne $((ctx_number-1)) ]; then
      new_list+=("${AVAILABLE_CONTEXTS[$j]}")
    fi
  done
  AVAILABLE_CONTEXTS=("${new_list[@]}")

done

echo ""
echo "Configuration written to: $OUTPUT_FILE"
echo "Please review API_SERVER, NAME, and fill IAAS_TYPE before deployment."