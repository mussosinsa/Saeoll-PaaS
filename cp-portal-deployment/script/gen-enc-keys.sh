#!/bin/bash

ENCRYPTION_ENABLE=${ENCRYPTION_ENABLE:-"true"}
ENCRYPTION_KEY_AUTO_GENERATED=${ENCRYPTION_KEY_AUTO_GENERATED:-"Y"}

KEY_OUT_DIR="../certs/enc_key"
mkdir -p "$KEY_OUT_DIR"

OUTPUT_YAML="../values/cp-portal-migration-secret.yaml"

gen_keys() {
  local p=$1

  # encryption disabled → skip
  [ "$ENCRYPTION_ENABLE" != "true" ] && return

  # Auto-generated
  if [ "$ENCRYPTION_KEY_AUTO_GENERATED" = "Y" ]; then
    eval "${p}_HMAC_KEY=\"$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)\""

    local priv="$KEY_OUT_DIR/${p}_priv.key"
    local pub="$KEY_OUT_DIR/${p}_pub.key"

    openssl genrsa -out "$priv" 4096
    openssl rsa -in "$priv" -out "$pub" -pubout

    eval "${p}_PRIVATE_KEY=\"$(<"$priv" sed ':a;N;$!ba;s/\n/\\n/g')\""
    eval "${p}_PUBLIC_KEY=\"$(<"$pub" sed ':a;N;$!ba;s/\n/\\n/g')\""
  else
    eval "${p}_HMAC_KEY=\"\$ENCRYPTION_${p}_HMAC_KEY\""
    eval "${p}_PRIVATE_KEY=\"\$ENCRYPTION_${p}_PRIVATE_KEY\""
    eval "${p}_PUBLIC_KEY=\"\$ENCRYPTION_${p}_PUBLIC_KEY\""
  fi
}

echo "▶ Generating encryption keys"
gen_keys MIG
echo " - migration key generated"
gen_keys AUTH
echo " - migration-auth key generated"

cat > "$OUTPUT_YAML" <<EOF
secretMigration:
  name: cp-portal-migration-secret
  data:
    IS_ENCRYPTION: "true"
    AUTH_HMAC_KEY: "${AUTH_HMAC_KEY}"
    AUTH_PRIVATE_KEY: |
$(echo -e "$AUTH_PRIVATE_KEY" | sed 's/^/      /')
    AUTH_PUBLIC_KEY: |
$(echo -e "$AUTH_PUBLIC_KEY" | sed 's/^/      /')

    MIG_HMAC_KEY: "${MIG_HMAC_KEY}"
    MIG_PRIVATE_KEY: |
$(echo -e "$MIG_PRIVATE_KEY" | sed 's/^/      /')
    MIG_PUBLIC_KEY: |
$(echo -e "$MIG_PUBLIC_KEY" | sed 's/^/      /')
EOF