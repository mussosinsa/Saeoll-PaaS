function generatedCA() {
  echo "Please wait for the certificate to be generated..."
  pushd "$CERT_DIR" >/dev/null

  openssl genrsa -out ca.key 4096

  openssl req -x509 -new -nodes -sha512 -days 3650 \
   -subj "/C=KR/ST=Seoul/L=Seoul/O=Personal/OU=Personal/CN=${HOST_DOMAIN}" \
   -key ca.key \
   -out ca.crt

  openssl genrsa -out ${HOST_DOMAIN}.key 4096

  openssl req -sha512 -new \
   -subj "/C=KR/ST=Seoul/L=Seoul/O=Personal/OU=Personal/CN=${HOST_DOMAIN}" \
   -key ${HOST_DOMAIN}.key \
   -out ${HOST_DOMAIN}.csr

  cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=*.${HOST_DOMAIN}
DNS.2=${HOST_DOMAIN}
EOF

  openssl x509 -req -sha512 -days 3650 \
      -extfile v3.ext \
      -CA ca.crt -CAkey ca.key -CAcreateserial \
      -in ${HOST_DOMAIN}.csr \
      -out ${HOST_DOMAIN}.crt

  popd >/dev/null
}

CERT_DIR="../certs"
mkdir -p "$CERT_DIR"

if [[ "$TLS_CERT_AUTO_GENERATED" == "N" ]]; then
  cp "$TLS_CERT_PATH" "${CERT_DIR}/${HOST_DOMAIN}.crt"
  cp "$TLS_KEY_PATH" "${CERT_DIR}/${HOST_DOMAIN}.key"
  chmod ug+r "${CERT_DIR}"/*
else
  generatedCA
fi