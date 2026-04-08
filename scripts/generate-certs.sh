#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# Generates self-signed TLS certificates for internal RUNE services (Zot registry, API, UI).

set -euo pipefail

OUT_DIR="${1:-certs}"
mkdir -p "${OUT_DIR}"
cd "${OUT_DIR}"

echo "Generating Root CA..."
openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
  -keyout ca.key -out ca.crt -subj "/CN=RUNE Airgapped Root CA"

generate_cert() {
  local service=$1
  local cn=$2
  local sans=$3
  echo "Generating certificate for ${service}..."
  
  openssl req -new -nodes -newkey rsa:2048 \
    -keyout "${service}.key" -out "${service}.csr" -subj "/CN=${cn}"
    
  cat > "${service}-extfile.cnf" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = ${sans}
EOF

  openssl x509 -req -in "${service}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${service}.crt" -days 825 -extfile "${service}-extfile.cnf"
    
  rm -f "${service}.csr" "${service}-extfile.cnf"
}

# Zot Registry
generate_cert "zot" "zot.rune-registry.svc.cluster.local" "DNS:zot.rune-registry.svc.cluster.local,DNS:zot.rune-registry.svc,DNS:zot,DNS:localhost"

# RUNE API
generate_cert "rune-api" "rune-api.rune.svc.cluster.local" "DNS:rune-api.rune.svc.cluster.local,DNS:rune-api.rune.svc,DNS:rune-api,DNS:localhost"

# RUNE UI
generate_cert "rune-ui" "rune-ui.rune.svc.cluster.local" "DNS:rune-ui.rune.svc.cluster.local,DNS:rune-ui.rune.svc,DNS:rune-ui,DNS:localhost"

echo "Certificates generated successfully in ${OUT_DIR}/"
