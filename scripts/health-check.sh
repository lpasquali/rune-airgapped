#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# health-check.sh — Post-deployment health check and smoke test for RUNE
# air-gapped Kubernetes deployments.
#
# Usage:
#   ./scripts/health-check.sh [OPTIONS]
#
# Dependencies: bash, kubectl
# Exit codes: 0 all checks pass, 1 one or more checks failed, 2 prerequisites missing

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
export SCRIPT_DIR  # Available to sub-scripts if needed

# Default ports
readonly ZOT_PORT=5000
readonly API_PORT=8080
readonly UI_PORT=8000

###############################################################################
# Defaults
###############################################################################

NAMESPACE="rune"
REGISTRY_NAMESPACE="rune-registry"
OPERATOR_NAMESPACE="rune-system"
VERBOSE=false
TIMEOUT=120
SKIP_REGISTRY=false
SKIP_API=false
SKIP_UI=false
LOG_FILE=""

###############################################################################
# Counters
###############################################################################

CHECK_PASS=0
CHECK_FAIL=0
CHECK_SKIP=0

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

Post-deployment health check and smoke test for RUNE air-gapped deployments.

Optional:
  --namespace NS             Application namespace (default: rune)
  --registry-namespace NS    Registry namespace (default: rune-registry)
  --operator-namespace NS    Operator namespace (default: rune-system)
  --verbose                  Enable verbose output
  --timeout SECONDS          Timeout for individual checks (default: 120)
  --skip-registry            Skip registry checks
  --skip-api                 Skip API server checks
  --skip-ui                  Skip UI checks
  -h, --help                 Show this help message

Exit codes:
  0  All checks passed
  1  One or more checks failed
  2  Prerequisites missing
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)           NAMESPACE="$2"; shift 2 ;;
            --registry-namespace)  REGISTRY_NAMESPACE="$2"; shift 2 ;;
            --operator-namespace)  OPERATOR_NAMESPACE="$2"; shift 2 ;;
            --verbose)             VERBOSE=true; shift ;;
            --timeout)             TIMEOUT="$2"; shift 2 ;;
            --skip-registry)       SKIP_REGISTRY=true; shift ;;
            --skip-api)            SKIP_API=true; shift ;;
            --skip-ui)             SKIP_UI=true; shift ;;
            -h|--help)             usage; exit 0 ;;
            *)                     log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

###############################################################################
# Check result helpers
###############################################################################

record_pass() {
    local name="$1"
    log_info "PASS: ${name}"
    CHECK_PASS=$((CHECK_PASS + 1))
}

record_fail() {
    local name="$1"
    local detail="${2:-}"
    log_error "FAIL: ${name}"
    if [[ -n "${detail}" ]]; then
        log_error "  Detail: ${detail}"
    fi
    CHECK_FAIL=$((CHECK_FAIL + 1))
}

record_skip() {
    local name="$1"
    log_info "SKIP: ${name}"
    CHECK_SKIP=$((CHECK_SKIP + 1))
}

###############################################################################
# Prerequisites
###############################################################################

check_prerequisites() {
    log_info "=== Checking prerequisites ==="

    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 2
    fi
    log_debug "kubectl found: $(command -v kubectl)"

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 2
    fi
    log_info "Cluster connectivity OK"
}

###############################################################################
# Check: Registry
###############################################################################

check_registry() {
    if [[ "${SKIP_REGISTRY}" == true ]]; then
        record_skip "registry"
        return 0
    fi

    log_info "=== Checking registry (namespace: ${REGISTRY_NAMESPACE}) ==="

    # Check zot pod is Running
    local pod_status
    pod_status="$(kubectl get pods -n "${REGISTRY_NAMESPACE}" \
        -l app.kubernetes.io/name=zot --no-headers 2>/dev/null || true)"

    if [[ -z "${pod_status}" ]]; then
        record_fail "registry-pod-exists" "No zot pods found in ${REGISTRY_NAMESPACE}"
        return 0
    fi

    log_debug "Registry pod status: ${pod_status}"

    if echo "${pod_status}" | grep -q "Running"; then
        record_pass "registry-pod-running"
    else
        record_fail "registry-pod-running" "Zot pod is not in Running state"
        return 0
    fi

    # Check /v2/_catalog endpoint via port-forward
    local pf_pid=""
    local pf_port
    pf_port="$((RANDOM % 10000 + 20000))"

    kubectl port-forward -n "${REGISTRY_NAMESPACE}" svc/zot \
        "${pf_port}:${ZOT_PORT}" &>/dev/null &
    pf_pid=$!
    sleep 2

    local catalog_response=""
    local catalog_exit=0
    catalog_response="$(curl -sf --max-time "${TIMEOUT}" \
        "http://localhost:${pf_port}/v2/_catalog" 2>/dev/null)" || catalog_exit=$?

    # Clean up port-forward
    if [[ -n "${pf_pid}" ]]; then
        kill "${pf_pid}" 2>/dev/null || true
        wait "${pf_pid}" 2>/dev/null || true
    fi

    if [[ "${catalog_exit}" -eq 0 && -n "${catalog_response}" ]]; then
        record_pass "registry-catalog-endpoint"
        log_debug "Catalog response: ${catalog_response}"
    else
        record_fail "registry-catalog-endpoint" "GET /v2/_catalog failed or empty"
    fi
}

###############################################################################
# Check: Operator
###############################################################################

check_operator() {
    log_info "=== Checking operator (namespace: ${OPERATOR_NAMESPACE}) ==="

    local pod_status
    pod_status="$(kubectl get pods -n "${OPERATOR_NAMESPACE}" --no-headers 2>/dev/null || true)"

    if [[ -z "${pod_status}" ]]; then
        record_fail "operator-pods-exist" "No pods found in ${OPERATOR_NAMESPACE}"
        return 0
    fi

    log_debug "Operator pods: ${pod_status}"

    local not_running
    not_running="$(echo "${pod_status}" | grep -v Running | grep -v Completed || true)"

    if [[ -z "${not_running}" ]]; then
        record_pass "operator-pods-running"
    else
        record_fail "operator-pods-running" "Non-running pods found: ${not_running}"
    fi
}

###############################################################################
# Check: API server
###############################################################################

check_api() {
    if [[ "${SKIP_API}" == true ]]; then
        record_skip "api"
        return 0
    fi

    log_info "=== Checking API server (namespace: ${NAMESPACE}) ==="

    # Check API pods are running
    local pod_status
    pod_status="$(kubectl get pods -n "${NAMESPACE}" \
        -l app.kubernetes.io/component=api --no-headers 2>/dev/null || true)"

    if [[ -z "${pod_status}" ]]; then
        # Fall back to broader label
        pod_status="$(kubectl get pods -n "${NAMESPACE}" \
            -l app.kubernetes.io/name=rune --no-headers 2>/dev/null || true)"
    fi

    if [[ -z "${pod_status}" ]]; then
        record_fail "api-pods-exist" "No API pods found in ${NAMESPACE}"
        return 0
    fi

    log_debug "API pods: ${pod_status}"

    if echo "${pod_status}" | grep -q "Running"; then
        record_pass "api-pods-running"
    else
        record_fail "api-pods-running" "API pod is not in Running state"
        return 0
    fi

    # Check /healthz endpoint via port-forward
    local pf_pid=""
    local pf_port
    pf_port="$((RANDOM % 10000 + 20000))"

    kubectl port-forward -n "${NAMESPACE}" svc/rune \
        "${pf_port}:${API_PORT}" &>/dev/null &
    pf_pid=$!
    sleep 2

    local health_code=""
    health_code="$(curl -sf -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
        "http://localhost:${pf_port}/healthz" 2>/dev/null)" || true

    # Clean up port-forward
    if [[ -n "${pf_pid}" ]]; then
        kill "${pf_pid}" 2>/dev/null || true
        wait "${pf_pid}" 2>/dev/null || true
    fi

    if [[ "${health_code}" == "200" ]]; then
        record_pass "api-healthz-200"
    else
        record_fail "api-healthz-200" "GET /healthz returned HTTP ${health_code:-timeout}"
    fi
}

###############################################################################
# Check: UI
###############################################################################

check_ui() {
    if [[ "${SKIP_UI}" == true ]]; then
        record_skip "ui"
        return 0
    fi

    log_info "=== Checking UI (namespace: ${NAMESPACE}) ==="

    # Check UI pods are running
    local pod_status
    pod_status="$(kubectl get pods -n "${NAMESPACE}" \
        -l app.kubernetes.io/component=ui --no-headers 2>/dev/null || true)"

    if [[ -z "${pod_status}" ]]; then
        pod_status="$(kubectl get pods -n "${NAMESPACE}" \
            -l app.kubernetes.io/name=rune-ui --no-headers 2>/dev/null || true)"
    fi

    if [[ -z "${pod_status}" ]]; then
        record_fail "ui-pods-exist" "No UI pods found in ${NAMESPACE}"
        return 0
    fi

    log_debug "UI pods: ${pod_status}"

    if echo "${pod_status}" | grep -q "Running"; then
        record_pass "ui-pods-running"
    else
        record_fail "ui-pods-running" "UI pod is not in Running state"
        return 0
    fi

    # Check UI port is accessible via port-forward
    local pf_pid=""
    local pf_port
    pf_port="$((RANDOM % 10000 + 20000))"

    kubectl port-forward -n "${NAMESPACE}" svc/rune-ui \
        "${pf_port}:${UI_PORT}" &>/dev/null &
    pf_pid=$!
    sleep 2

    local ui_code=""
    ui_code="$(curl -sf -o /dev/null -w '%{http_code}' --max-time "${TIMEOUT}" \
        "http://localhost:${pf_port}/" 2>/dev/null)" || true

    # Clean up port-forward
    if [[ -n "${pf_pid}" ]]; then
        kill "${pf_pid}" 2>/dev/null || true
        wait "${pf_pid}" 2>/dev/null || true
    fi

    if [[ -n "${ui_code}" && "${ui_code}" != "000" ]]; then
        record_pass "ui-port-accessible"
        log_debug "UI HTTP response code: ${ui_code}"
    else
        record_fail "ui-port-accessible" "UI port not reachable (HTTP ${ui_code:-timeout})"
    fi
}

###############################################################################
# Check: Network connectivity between namespaces
###############################################################################

check_network() {
    log_info "=== Checking cross-namespace network connectivity ==="

    if [[ "${SKIP_REGISTRY}" == true || "${SKIP_API}" == true ]]; then
        record_skip "network-api-to-registry"
        return 0
    fi

    # Verify API namespace pods can resolve the registry service
    local registry_svc="zot.${REGISTRY_NAMESPACE}.svc.cluster.local"

    # Pick an API pod to test from
    local api_pod
    api_pod="$(kubectl get pods -n "${NAMESPACE}" \
        -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -z "${api_pod}" ]]; then
        api_pod="$(kubectl get pods -n "${NAMESPACE}" \
            -l app.kubernetes.io/name=rune -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi

    if [[ -z "${api_pod}" ]]; then
        record_fail "network-api-to-registry" "No API pod available to test connectivity"
        return 0
    fi

    log_debug "Testing connectivity from pod ${api_pod} to ${registry_svc}"

    local nslookup_exit=0
    kubectl exec -n "${NAMESPACE}" "${api_pod}" -- \
        sh -c "getent hosts ${registry_svc} 2>/dev/null || nslookup ${registry_svc} 2>/dev/null" \
        &>/dev/null || nslookup_exit=$?

    if [[ "${nslookup_exit}" -eq 0 ]]; then
        record_pass "network-api-to-registry"
    else
        record_fail "network-api-to-registry" \
            "Pod ${api_pod} cannot resolve ${registry_svc}"
    fi
}

###############################################################################
# Summary
###############################################################################

print_summary() {
    local total=$((CHECK_PASS + CHECK_FAIL + CHECK_SKIP))
    echo ""
    echo "=== Health Check Summary ==="
    echo "  Total:   ${total}"
    echo "  Passed:  ${CHECK_PASS}"
    echo "  Failed:  ${CHECK_FAIL}"
    echo "  Skipped: ${CHECK_SKIP}"
    echo ""

    if [[ "${CHECK_FAIL}" -gt 0 ]]; then
        echo "Result: FAILED"
        return 1
    else
        echo "Result: PASSED"
        return 0
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    LOG_FILE="health-check-$(date -u '+%Y%m%dT%H%M%SZ').log"
    log_info "=== RUNE Post-Deployment Health Check ==="
    log_info "Log file: ${LOG_FILE}"
    log_debug "Namespace: ${NAMESPACE}, Registry: ${REGISTRY_NAMESPACE}, Operator: ${OPERATOR_NAMESPACE}"
    log_debug "Timeout: ${TIMEOUT}s"

    check_prerequisites

    check_registry
    check_operator
    check_api
    check_ui
    check_network

    print_summary
}

main "$@"
