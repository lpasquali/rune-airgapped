#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# generate-tls.sh — Generate TLS certificates for RUNE internal services
# in an air-gapped Kubernetes cluster.
#
# Usage:
#   ./scripts/generate-tls.sh --output-dir ./tls
#   ./scripts/generate-tls.sh --ca-cert ca.crt --ca-key ca.key --namespace prod
#   ./scripts/generate-tls.sh --apply --namespace rune --san extra.example.com
#
# Dependencies: bash, openssl
# Exit codes: 0 success, 1 error, 2 prerequisites missing (openssl not found)

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Internal services that require TLS certificates
readonly SERVICES=("rune-api" "rune-ui" "rune-registry")

# OpenSSL key parameters
readonly KEY_BITS=2048
readonly CA_SUBJECT="/CN=RUNE Internal CA/O=RUNE/OU=Air-Gapped"

###############################################################################
# Defaults
###############################################################################

NAMESPACE="rune"
OUTPUT_DIR="./tls"
CA_CERT=""
CA_KEY=""
DAYS=365
DRY_RUN=false
VERBOSE=false
APPLY=false
EXTRA_SANS=()
LOG_FILE=""

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local msg
    msg="$(printf '[%s] [%s] %s' "$ts" "$level" "$*")"
    echo "${msg}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
        echo "${msg}" >> "${LOG_FILE}"
    fi
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { if [[ "${VERBOSE}" == true ]]; then log "DEBUG" "$@"; fi; }

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Generate TLS certificates for RUNE internal services.

Modes:
  Self-signed (default)    Generate a new CA and sign server certificates
  Customer CA              Use --ca-cert and --ca-key to sign with your own CA

Optional:
  --namespace NS           Kubernetes namespace for SAN generation (default: rune)
  --output-dir DIR         Output directory for certificates (default: ./tls)
  --ca-cert FILE           Path to existing CA certificate (customer CA mode)
  --ca-key FILE            Path to existing CA private key (customer CA mode)
  --days N                 Certificate validity in days (default: 365)
  --san HOSTNAME           Additional SAN entry (repeatable)
  --apply                  Create Kubernetes TLS secrets after generation
  --dry-run                Preview actions without making changes
  --verbose                Enable verbose output
  -h, --help               Show this help message

Services:
  Certificates are generated for: ${SERVICES[*]}
  Each service gets SAN entries for:
    <service>.<namespace>.svc.cluster.local
    <service>.<namespace>.svc
    <service>

Exit codes:
  0  Certificates generated (and applied) successfully
  1  Error during generation or application
  2  Prerequisites missing (openssl not found)
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)    NAMESPACE="$2"; shift 2 ;;
            --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
            --ca-cert)      CA_CERT="$2"; shift 2 ;;
            --ca-key)       CA_KEY="$2"; shift 2 ;;
            --days)         DAYS="$2"; shift 2 ;;
            --san)          EXTRA_SANS+=("$2"); shift 2 ;;
            --apply)        APPLY=true; shift ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --verbose)      VERBOSE=true; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Validate customer CA mode: both or neither must be provided
    if [[ -n "${CA_CERT}" && -z "${CA_KEY}" ]]; then
        log_error "--ca-cert requires --ca-key"
        exit 1
    fi
    if [[ -z "${CA_CERT}" && -n "${CA_KEY}" ]]; then
        log_error "--ca-key requires --ca-cert"
        exit 1
    fi

    # Validate files exist if customer CA mode
    if [[ -n "${CA_CERT}" && ! -f "${CA_CERT}" ]]; then
        log_error "CA certificate file not found: ${CA_CERT}"
        exit 1
    fi
    if [[ -n "${CA_KEY}" && ! -f "${CA_KEY}" ]]; then
        log_error "CA key file not found: ${CA_KEY}"
        exit 1
    fi

    # Validate --days is a positive integer
    if ! [[ "${DAYS}" =~ ^[0-9]+$ ]] || [[ "${DAYS}" -le 0 ]]; then
        log_error "--days must be a positive integer: ${DAYS}"
        exit 1
    fi
}

###############################################################################
# Prerequisites
###############################################################################

check_prerequisites() {
    log_info "Checking prerequisites"

    if ! command -v openssl &>/dev/null; then
        log_error "openssl is required but not found in PATH"
        exit 2
    fi

    local openssl_version
    openssl_version="$(openssl version 2>/dev/null)" || true
    log_info "Found: ${openssl_version}"

    if [[ "${APPLY}" == true ]]; then
        if ! command -v kubectl &>/dev/null; then
            log_error "kubectl is required for --apply but not found in PATH"
            exit 2
        fi
        log_info "Found: kubectl"
    fi
}

###############################################################################
# Certificate generation helpers
###############################################################################

generate_ca() {
    local ca_dir="$1"

    log_info "Generating self-signed CA"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would generate CA key: ${ca_dir}/ca.key"
        log_info "[DRY RUN] Would generate CA cert: ${ca_dir}/ca.crt"
        return 0
    fi

    openssl genrsa -out "${ca_dir}/ca.key" "${KEY_BITS}" 2>/dev/null
    openssl req -new -x509 \
        -key "${ca_dir}/ca.key" \
        -out "${ca_dir}/ca.crt" \
        -days "${DAYS}" \
        -subj "${CA_SUBJECT}" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        2>/dev/null

    log_info "CA certificate generated: ${ca_dir}/ca.crt"
    log_debug "CA subject: ${CA_SUBJECT}"
}

build_san_list() {
    local service="$1"
    local san_list=""

    # Standard Kubernetes DNS names
    san_list="DNS:${service}.${NAMESPACE}.svc.cluster.local"
    san_list="${san_list},DNS:${service}.${NAMESPACE}.svc"
    san_list="${san_list},DNS:${service}"

    # Add extra SANs
    for san in "${EXTRA_SANS[@]+"${EXTRA_SANS[@]}"}"; do
        if [[ -n "${san}" ]]; then
            san_list="${san_list},DNS:${san}"
        fi
    done

    echo "${san_list}"
}

generate_server_cert() {
    local service="$1"
    local ca_cert_path="$2"
    local ca_key_path="$3"
    local out_dir="$4"

    local service_dir="${out_dir}/${service}"
    local san_list
    san_list="$(build_san_list "${service}")"

    log_info "Generating certificate for ${service}"
    log_debug "SANs: ${san_list}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would generate key:  ${service_dir}/server.key"
        log_info "[DRY RUN] Would generate cert: ${service_dir}/server.crt"
        log_info "[DRY RUN] SANs: ${san_list}"
        return 0
    fi

    mkdir -p "${service_dir}"

    # Generate private key
    openssl genrsa -out "${service_dir}/server.key" "${KEY_BITS}" 2>/dev/null

    # Generate CSR with SANs
    openssl req -new \
        -key "${service_dir}/server.key" \
        -out "${service_dir}/server.csr" \
        -subj "/CN=${service}/O=RUNE/OU=${NAMESPACE}" \
        -addext "subjectAltName=${san_list}" \
        2>/dev/null

    # Sign with CA
    openssl x509 -req \
        -in "${service_dir}/server.csr" \
        -CA "${ca_cert_path}" \
        -CAkey "${ca_key_path}" \
        -CAcreateserial \
        -out "${service_dir}/server.crt" \
        -days "${DAYS}" \
        -copy_extensions copyall \
        2>/dev/null

    # Clean up CSR (not needed after signing)
    rm -f "${service_dir}/server.csr"

    log_info "Certificate generated: ${service_dir}/server.crt"
}

###############################################################################
# Validation
###############################################################################

validate_cert() {
    local service="$1"
    local ca_cert_path="$2"
    local out_dir="$3"

    local service_dir="${out_dir}/${service}"
    local cert_path="${service_dir}/server.crt"
    local key_path="${service_dir}/server.key"

    log_info "Validating certificate for ${service}"

    # Verify cert against CA
    if ! openssl verify -CAfile "${ca_cert_path}" "${cert_path}" >/dev/null 2>&1; then
        log_error "Certificate verification FAILED for ${service}"
        return 1
    fi
    log_debug "CA verification passed for ${service}"

    # Verify key matches cert
    local cert_modulus key_modulus
    cert_modulus="$(openssl x509 -noout -modulus -in "${cert_path}" 2>/dev/null)"
    key_modulus="$(openssl rsa -noout -modulus -in "${key_path}" 2>/dev/null)"
    if [[ "${cert_modulus}" != "${key_modulus}" ]]; then
        log_error "Key/certificate mismatch for ${service}"
        return 1
    fi
    log_debug "Key/cert match verified for ${service}"

    # Check SANs are present
    local san_output
    san_output="$(openssl x509 -noout -text -in "${cert_path}" 2>/dev/null | grep -A1 "Subject Alternative Name")" || true
    if [[ -z "${san_output}" ]]; then
        log_error "No SANs found in certificate for ${service}"
        return 1
    fi
    log_debug "SANs present for ${service}: ${san_output}"

    log_info "Validation PASSED for ${service}"
    return 0
}

###############################################################################
# Kubernetes secret creation
###############################################################################

apply_secrets() {
    local ca_cert_path="$1"
    local out_dir="$2"

    log_info "Applying TLS secrets to Kubernetes namespace: ${NAMESPACE}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would create secret: ${NAMESPACE}/rune-ca-tls"
        for service in "${SERVICES[@]}"; do
            log_info "[DRY RUN] Would create secret: ${NAMESPACE}/${service}-tls"
        done
        return 0
    fi

    # Create CA secret (generic, not TLS type — CA cert only)
    kubectl create secret generic rune-ca-tls \
        --namespace "${NAMESPACE}" \
        --from-file=ca.crt="${ca_cert_path}" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_info "Applied secret: ${NAMESPACE}/rune-ca-tls"

    for service in "${SERVICES[@]}"; do
        local service_dir="${out_dir}/${service}"
        kubectl create secret tls "${service}-tls" \
            --namespace "${NAMESPACE}" \
            --cert="${service_dir}/server.crt" \
            --key="${service_dir}/server.key" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_info "Applied secret: ${NAMESPACE}/${service}-tls"
    done

    log_info "All TLS secrets applied"
}

###############################################################################
# Summary
###############################################################################

print_summary() {
    local ca_cert_path="$1"
    local out_dir="$2"
    local mode="$3"

    echo ""
    echo "=== TLS Certificate Generation Summary ==="
    echo "Mode:        ${mode}"
    echo "Namespace:   ${NAMESPACE}"
    echo "Output:      ${out_dir}"
    echo "Validity:    ${DAYS} days"
    echo "CA cert:     ${ca_cert_path}"
    echo ""
    echo "Services:"
    for service in "${SERVICES[@]}"; do
        if [[ "${DRY_RUN}" == true ]]; then
            echo "  ${service}: (dry run — no files created)"
        else
            echo "  ${service}:"
            echo "    cert: ${out_dir}/${service}/server.crt"
            echo "    key:  ${out_dir}/${service}/server.key"
        fi
    done
    if [[ "${APPLY}" == true ]]; then
        echo ""
        if [[ "${DRY_RUN}" == true ]]; then
            echo "Secrets: (dry run — not applied)"
        else
            echo "Secrets: applied to namespace ${NAMESPACE}"
        fi
    fi
    echo ""
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    # Initialise log file
    LOG_FILE="generate-tls-$(date -u '+%Y%m%dT%H%M%SZ').log"
    log_info "=== RUNE TLS Certificate Generation ==="
    log_debug "Namespace: ${NAMESPACE}, Output: ${OUTPUT_DIR}, Days: ${DAYS}"

    check_prerequisites

    # Determine mode
    local mode="self-signed"
    local ca_cert_path="${OUTPUT_DIR}/ca.crt"
    local ca_key_path="${OUTPUT_DIR}/ca.key"

    if [[ -n "${CA_CERT}" ]]; then
        mode="customer-ca"
        ca_cert_path="${CA_CERT}"
        ca_key_path="${CA_KEY}"
        log_info "Using customer-provided CA: ${CA_CERT}"
    fi

    # Create output directory
    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would create output directory: ${OUTPUT_DIR}"
    else
        mkdir -p "${OUTPUT_DIR}"
        log_info "Output directory: ${OUTPUT_DIR}"
    fi

    # Generate or use existing CA
    if [[ "${mode}" == "self-signed" ]]; then
        generate_ca "${OUTPUT_DIR}"
    fi

    # Generate server certificates for each service
    for service in "${SERVICES[@]}"; do
        generate_server_cert "${service}" "${ca_cert_path}" "${ca_key_path}" "${OUTPUT_DIR}"
    done

    # Validate certificates (skip in dry-run since no files are created)
    if [[ "${DRY_RUN}" != true ]]; then
        local validation_ok=true
        for service in "${SERVICES[@]}"; do
            if ! validate_cert "${service}" "${ca_cert_path}" "${OUTPUT_DIR}"; then
                validation_ok=false
            fi
        done

        if [[ "${validation_ok}" != true ]]; then
            log_error "Certificate validation FAILED — not applying secrets"
            exit 1
        fi
    fi

    # Apply to Kubernetes if requested
    if [[ "${APPLY}" == true ]]; then
        apply_secrets "${ca_cert_path}" "${OUTPUT_DIR}"
    fi

    print_summary "${ca_cert_path}" "${OUTPUT_DIR}" "${mode}"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "=== DRY RUN complete (no changes made) ==="
    else
        log_info "=== TLS certificate generation complete ==="
    fi
}

main "$@"
