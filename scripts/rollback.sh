#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# rollback.sh — Roll back RUNE Helm releases in an air-gapped Kubernetes
# cluster to a previous revision. Shows current and target revision info,
# performs Helm rollback, waits for pod stabilisation, and runs health checks.
#
# Usage:
#   ./scripts/rollback.sh --namespace rune
#   ./scripts/rollback.sh --component rune-operator --revision 3
#
# Dependencies: bash, kubectl, helm
# Exit codes: 0 success, 1 error

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
export SCRIPT_DIR  # Used by sub-scripts (health-check)

# Helm release ordering (must match bootstrap.sh — reversed for rollback)
readonly -a ROLLBACK_ORDER=("rune-ui" "rune" "rune-operator")

###############################################################################
# Defaults
###############################################################################

NAMESPACE="rune"
OPERATOR_NAMESPACE="rune-system"
REGISTRY_NAMESPACE="rune-registry"
COMPONENT=""
REVISION=""
DRY_RUN=false
VERBOSE=false
LOG_FILE=""

###############################################################################
# Logging (identical to bootstrap.sh)
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

Roll back RUNE Helm releases to a previous revision.

Optional:
  --namespace NS             Application namespace (default: rune)
  --operator-namespace NS    Operator namespace (default: rune-system)
  --registry-namespace NS    Registry namespace (default: rune-registry)
  --component NAME           Roll back a specific component only (rune-operator, rune, rune-ui)
  --revision NUM             Target revision number (default: previous revision)
  --dry-run                  Preview rollback plan without making changes
  --verbose                  Enable verbose output
  -h, --help                 Show this help message

Exit codes:
  0  Rollback completed successfully
  1  Error during rollback
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace)           NAMESPACE="$2"; shift 2 ;;
            --operator-namespace)  OPERATOR_NAMESPACE="$2"; shift 2 ;;
            --registry-namespace)  REGISTRY_NAMESPACE="$2"; shift 2 ;;
            --component)           COMPONENT="$2"; shift 2 ;;
            --revision)            REVISION="$2"; shift 2 ;;
            --dry-run)             DRY_RUN=true; shift ;;
            --verbose)             VERBOSE=true; shift ;;
            -h|--help)             usage; exit 0 ;;
            *)                     log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -n "${COMPONENT}" ]]; then
        local valid=false
        for c in "${ROLLBACK_ORDER[@]}"; do
            if [[ "${c}" == "${COMPONENT}" ]]; then
                valid=true
                break
            fi
        done
        if [[ "${valid}" == false ]]; then
            log_error "Invalid component: ${COMPONENT}. Must be one of: ${ROLLBACK_ORDER[*]}"
            exit 1
        fi
    fi

    if [[ -n "${REVISION}" ]]; then
        if ! [[ "${REVISION}" =~ ^[0-9]+$ ]]; then
            log_error "Invalid revision: ${REVISION}. Must be a positive integer."
            exit 1
        fi
    fi
}

###############################################################################
# Resolve target namespace for a component
###############################################################################

namespace_for() {
    local component="$1"
    if [[ "${component}" == "rune-operator" ]]; then
        echo "${OPERATOR_NAMESPACE}"
    else
        echo "${NAMESPACE}"
    fi
}

###############################################################################
# Build list of components to roll back
###############################################################################

components_to_rollback() {
    if [[ -n "${COMPONENT}" ]]; then
        echo "${COMPONENT}"
    else
        printf '%s\n' "${ROLLBACK_ORDER[@]}"
    fi
}

###############################################################################
# Phase 1: Show current and target revision info
###############################################################################

phase_show_revisions() {
    log_info "=== Phase 1: Current and target revision info ==="

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        # Get current revision
        local current_rev
        current_rev="$(helm list -n "${target_ns}" --filter "^${component}$" -o json 2>/dev/null \
            | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['revision'] if data else '')" 2>/dev/null)" || true

        if [[ -z "${current_rev}" ]]; then
            log_warn "${component}: no Helm release found in ${target_ns} — skipping"
            continue
        fi

        local target_rev="${REVISION:-$((current_rev - 1))}"
        if [[ "${target_rev}" -lt 1 ]]; then
            log_warn "${component}: current revision is ${current_rev}, no previous revision to roll back to"
            continue
        fi

        log_info "${component} (namespace: ${target_ns}):"
        log_info "  Current revision: ${current_rev}"
        log_info "  Target revision:  ${target_rev}"

        if [[ "${VERBOSE}" == true && "${DRY_RUN}" != true ]]; then
            local history
            history="$(helm history "${component}" -n "${target_ns}" --max 5 2>/dev/null)" || true
            if [[ -n "${history}" ]]; then
                log_debug "  Recent history:"
                while IFS= read -r line; do
                    log_debug "    ${line}"
                done <<< "${history}"
            fi
        fi
    done < <(components_to_rollback)
}

###############################################################################
# Phase 2: Helm rollback each component
###############################################################################

phase_helm_rollback() {
    log_info "=== Phase 2: Helm rollback ==="

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        # Get current revision
        local current_rev
        current_rev="$(helm list -n "${target_ns}" --filter "^${component}$" -o json 2>/dev/null \
            | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['revision'] if data else '')" 2>/dev/null)" || true

        if [[ -z "${current_rev}" ]]; then
            log_warn "${component}: no Helm release found — skipping"
            continue
        fi

        local target_rev="${REVISION:-$((current_rev - 1))}"
        if [[ "${target_rev}" -lt 1 ]]; then
            log_warn "${component}: no previous revision available — skipping"
            continue
        fi

        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY RUN] Would rollback ${component} from revision ${current_rev} to ${target_rev} in ${target_ns}"
            continue
        fi

        log_info "Rolling back ${component} from revision ${current_rev} to ${target_rev}"
        if ! helm rollback "${component}" "${target_rev}" \
                -n "${target_ns}" \
                --wait \
                --timeout 300s; then
            log_error "Failed to rollback ${component}"
            exit 1
        fi

        log_info "${component} rolled back to revision ${target_rev}"
    done < <(components_to_rollback)
}

###############################################################################
# Phase 3: Wait for pods to stabilise
###############################################################################

phase_wait_pods() {
    log_info "=== Phase 3: Waiting for pods to stabilise ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would wait for pods to stabilise"
        return 0
    fi

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        # Check if the release exists
        local exists
        exists="$(helm list -n "${target_ns}" --filter "^${component}$" -o json 2>/dev/null \
            | python3 -c "import json,sys; data=json.load(sys.stdin); print('yes' if data else '')" 2>/dev/null)" || true

        if [[ -z "${exists}" ]]; then
            continue
        fi

        log_info "Waiting for ${component} pods in ${target_ns}"

        # Wait for deployments to stabilise
        local deployments
        deployments="$(kubectl get deployments -n "${target_ns}" -o name 2>/dev/null)" || true
        while IFS= read -r deploy; do
            if [[ -n "${deploy}" ]]; then
                log_debug "Waiting for ${deploy}"
                kubectl rollout status "${deploy}" \
                    -n "${target_ns}" \
                    --timeout=120s 2>/dev/null || \
                    log_warn "Timeout waiting for ${deploy}"
            fi
        done <<< "${deployments}"
    done < <(components_to_rollback)

    log_info "Pod stabilisation complete"
}

###############################################################################
# Phase 4: Health checks
###############################################################################

phase_health_check() {
    log_info "=== Phase 4: Post-rollback health checks ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would run health checks"
        return 0
    fi

    # Use health-check.sh if available
    local health_script="${SCRIPT_DIR}/health-check.sh"
    if [[ -x "${health_script}" ]]; then
        log_info "Running health-check.sh"
        if ! bash "${health_script}" \
                --namespace "${NAMESPACE}" \
                --operator-namespace "${OPERATOR_NAMESPACE}" \
                --registry-namespace "${REGISTRY_NAMESPACE}"; then
            log_error "Post-rollback health check FAILED — manual intervention required"
            exit 1
        fi
        log_info "Health check PASSED"
        return 0
    fi

    # Fallback: basic pod readiness check
    log_info "health-check.sh not found — running basic pod readiness check"
    local exit_ok=true

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        log_info "Checking pods for ${component} in ${target_ns}"
        local not_running
        not_running="$(kubectl get pods -n "${target_ns}" --no-headers 2>/dev/null \
            | grep -v Running | grep -v Completed || true)"
        if [[ -n "${not_running}" ]]; then
            log_error "Non-running pods in ${target_ns}:"
            echo "${not_running}" >&2
            exit_ok=false
        else
            log_info "All pods in ${target_ns}: Running"
        fi
    done < <(components_to_rollback)

    if [[ "${exit_ok}" == false ]]; then
        log_error "Post-rollback health check FAILED"
        exit 1
    fi

    log_info "Health check PASSED"
}

###############################################################################
# Dry-run summary
###############################################################################

print_dry_run_summary() {
    echo ""
    echo "=== ROLLBACK PLAN ==="
    echo "Namespace:           ${NAMESPACE}"
    echo "Operator namespace:  ${OPERATOR_NAMESPACE}"
    echo "Component filter:    ${COMPONENT:-all}"
    echo "Target revision:     ${REVISION:-previous}"
    echo ""
    echo "Components to roll back (reverse deployment order):"
    local component
    while IFS= read -r component; do
        echo "  - ${component} (namespace: $(namespace_for "${component}"))"
    done < <(components_to_rollback)
    echo ""
    echo "Phases:"
    echo "  1. Show current and target revision info"
    echo "  2. Helm rollback each component"
    echo "  3. Wait for pods to stabilise"
    echo "  4. Post-rollback health checks"
    echo ""
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    # Initialise log file
    LOG_FILE="rollback-$(date -u '+%Y%m%dT%H%M%SZ').log"
    log_info "=== RUNE Air-Gapped Rollback ==="
    log_info "Log file: ${LOG_FILE}"
    log_debug "Namespace: ${NAMESPACE}, Operator: ${OPERATOR_NAMESPACE}"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run_summary
    fi

    # Execute phases
    phase_show_revisions
    phase_helm_rollback
    phase_wait_pods
    phase_health_check

    log_info "=== RUNE rollback complete ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "=== DRY RUN complete (no changes made) ==="
    else
        echo ""
        echo "RUNE has been rolled back successfully."
        echo "  Namespace: ${NAMESPACE}"
        echo "  Log:       ${LOG_FILE}"
    fi
}

main "$@"
