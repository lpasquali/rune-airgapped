#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# upgrade.sh — Upgrade RUNE components in an air-gapped Kubernetes cluster
# from a new OCI bundle. Backs up current Helm values, loads new images,
# performs Helm upgrade --install, and auto-rolls back on health-check failure.
#
# Usage:
#   ./scripts/upgrade.sh \
#     --bundle /path/to/rune-bundle-v0.0.0a3.tar.gz \
#     --namespace rune
#
# Dependencies: bash, tar, kubectl, helm, crane (bundled or PATH)
# Exit codes: 0 success, 1 error, 2 prerequisites missing, 3 rollback triggered

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
export SCRIPT_DIR  # Used by sub-scripts (health-check, rollback)

# Helm release ordering (must match bootstrap.sh)
readonly -a DEPLOY_ORDER=("rune-operator" "rune" "rune-ui")

# Zot registry defaults
readonly ZOT_PORT=5000

###############################################################################
# Defaults
###############################################################################

BUNDLE=""
NAMESPACE="rune"
REGISTRY_NAMESPACE="rune-registry"
OPERATOR_NAMESPACE="rune-system"
DRY_RUN=false
VERBOSE=false
SKIP_BACKUP=false
VALUES_FILE=""
COMPONENT=""
WORK_DIR=""
LOG_FILE=""
BACKUP_DIR=""

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

Upgrade RUNE components from a new air-gapped OCI bundle.

Required:
  --bundle FILE              Path to new RUNE bundle tarball

Optional:
  --namespace NS             Application namespace (default: rune)
  --registry-namespace NS    Registry namespace (default: rune-registry)
  --operator-namespace NS    Operator namespace (default: rune-system)
  --dry-run                  Preview upgrade plan without making changes
  --verbose                  Enable verbose output
  --skip-backup              Skip Helm release value backup (not recommended)
  --values FILE              Custom Helm values overlay file
  --component NAME           Upgrade a specific component only (rune-operator, rune, rune-ui)
  -h, --help                 Show this help message

Exit codes:
  0  Upgrade completed successfully
  1  Error during upgrade
  2  Prerequisites missing (no changes made)
  3  Rollback triggered due to health-check failure
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)              BUNDLE="$2"; shift 2 ;;
            --namespace)           NAMESPACE="$2"; shift 2 ;;
            --registry-namespace)  REGISTRY_NAMESPACE="$2"; shift 2 ;;
            --operator-namespace)  OPERATOR_NAMESPACE="$2"; shift 2 ;;
            --dry-run)             DRY_RUN=true; shift ;;
            --verbose)             VERBOSE=true; shift ;;
            --skip-backup)         SKIP_BACKUP=true; shift ;;
            --values)              VALUES_FILE="$2"; shift 2 ;;
            --component)           COMPONENT="$2"; shift 2 ;;
            -h|--help)             usage; exit 0 ;;
            *)                     log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${BUNDLE}" ]]; then
        log_error "--bundle is required"
        usage
        exit 1
    fi

    if [[ ! -f "${BUNDLE}" ]]; then
        log_error "Bundle file not found: ${BUNDLE}"
        exit 1
    fi

    if [[ -n "${VALUES_FILE}" && ! -f "${VALUES_FILE}" ]]; then
        log_error "Values file not found: ${VALUES_FILE}"
        exit 1
    fi

    if [[ -n "${COMPONENT}" ]]; then
        local valid=false
        for c in "${DEPLOY_ORDER[@]}"; do
            if [[ "${c}" == "${COMPONENT}" ]]; then
                valid=true
                break
            fi
        done
        if [[ "${valid}" == false ]]; then
            log_error "Invalid component: ${COMPONENT}. Must be one of: ${DEPLOY_ORDER[*]}"
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
# Build list of components to upgrade
###############################################################################

components_to_upgrade() {
    if [[ -n "${COMPONENT}" ]]; then
        echo "${COMPONENT}"
    else
        printf '%s\n' "${DEPLOY_ORDER[@]}"
    fi
}

###############################################################################
# Phase 1: Validate new bundle (checksums)
###############################################################################

phase_validate_bundle() {
    log_info "=== Phase 1: Validating new bundle ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would unpack and verify: ${BUNDLE}"
        return 0
    fi

    tar xzf "${BUNDLE}" -C "${WORK_DIR}/"

    local bundle_dir
    bundle_dir="$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [[ -z "${bundle_dir}" ]]; then
        log_error "Bundle extraction failed: no directory found"
        exit 1
    fi

    BUNDLE_DIR="${bundle_dir}"
    log_info "Bundle unpacked to: ${BUNDLE_DIR}"

    # Verify checksums
    local sums_file="${BUNDLE_DIR}/SHA256SUMS"
    if [[ -f "${sums_file}" ]]; then
        log_info "Verifying SHA256 checksums"
        if ! (cd "${BUNDLE_DIR}" && sha256sum -c SHA256SUMS --quiet 2>&1); then
            log_error "SHA256 checksum verification FAILED"
            exit 1
        fi
        log_info "SHA256 checksum verification PASSED"
    else
        log_warn "No SHA256SUMS in bundle — skipping checksum verification"
    fi
}

###############################################################################
# Phase 2: Back up current Helm release values
###############################################################################

phase_backup() {
    log_info "=== Phase 2: Backing up current Helm release values ==="

    if [[ "${SKIP_BACKUP}" == true ]]; then
        log_warn "Skipping backup (--skip-backup)"
        return 0
    fi

    BACKUP_DIR="${WORK_DIR}/backup-$(date -u '+%Y%m%dT%H%M%SZ')"
    mkdir -p "${BACKUP_DIR}"

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY RUN] Would backup values for ${component} in ${target_ns}"
            continue
        fi

        local revision
        revision="$(helm list -n "${target_ns}" --filter "^${component}$" -o json 2>/dev/null \
            | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['revision'] if data else '')" 2>/dev/null)" || true

        if [[ -z "${revision}" ]]; then
            log_info "No existing release for ${component} — nothing to backup"
            continue
        fi

        log_info "Backing up ${component} (revision ${revision}) values"
        helm get values "${component}" -n "${target_ns}" -o yaml \
            > "${BACKUP_DIR}/${component}-values.yaml" 2>/dev/null || true
        helm get values "${component}" -n "${target_ns}" --all -o yaml \
            > "${BACKUP_DIR}/${component}-values-all.yaml" 2>/dev/null || true

        # Record current revision for potential rollback
        echo "${revision}" > "${BACKUP_DIR}/${component}-revision.txt"
        log_info "Backed up ${component} revision ${revision}"
    done < <(components_to_upgrade)

    if [[ "${DRY_RUN}" != true ]]; then
        log_info "Backup saved to: ${BACKUP_DIR}"
    fi
}

###############################################################################
# Phase 3: Load new images into registry (crane push)
###############################################################################

phase_load_images() {
    log_info "=== Phase 3: Loading new images into registry ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would load images from ${BUNDLE_DIR:-<bundle>}/images into registry"
        return 0
    fi

    if [[ ! -d "${BUNDLE_DIR}/images" ]]; then
        log_warn "No images directory found in bundle — skipping image load"
        return 0
    fi

    # Set up port-forward for image loading
    local pf_pid=""
    kubectl port-forward -n "${REGISTRY_NAMESPACE}" svc/zot "${ZOT_PORT}:${ZOT_PORT}" &
    pf_pid=$!
    sleep 3

    local local_registry="localhost:${ZOT_PORT}"

    while IFS= read -r img_dir; do
        local img_name
        img_name="$(basename "${img_dir}")"
        log_info "Loading image: ${img_name}"

        while IFS= read -r arch_dir; do
            if [[ -d "${arch_dir}" ]]; then
                if command -v crane &>/dev/null; then
                    crane push "${arch_dir}" "${local_registry}/${img_name}:latest" --image-refs=- 2>&1 || \
                        log_warn "Failed to push ${img_name} from ${arch_dir}"
                else
                    log_warn "crane not available for image loading; images must be loaded manually"
                fi
            fi
        done < <(find "${img_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
    done < <(find "${BUNDLE_DIR}/images" -mindepth 1 -maxdepth 1 -type d | sort)

    # Clean up port-forward
    if [[ -n "${pf_pid}" ]]; then
        kill "${pf_pid}" 2>/dev/null || true
        wait "${pf_pid}" 2>/dev/null || true
    fi

    log_info "Image loading complete"
}

###############################################################################
# Phase 4: Helm upgrade --install each component
###############################################################################

phase_helm_upgrade() {
    log_info "=== Phase 4: Helm upgrade ==="

    local registry_url="zot.${REGISTRY_NAMESPACE}.svc.cluster.local:${ZOT_PORT}"
    local charts_dir="${BUNDLE_DIR:-}/charts"

    if [[ "${DRY_RUN}" != true && ! -d "${charts_dir}" ]]; then
        log_warn "No charts directory in bundle — skipping Helm upgrade"
        return 0
    fi

    # Build values args
    local values_args=()
    if [[ -n "${VALUES_FILE}" ]]; then
        values_args+=(--values "${VALUES_FILE}")
    fi

    local component
    while IFS= read -r component; do
        local target_ns
        target_ns="$(namespace_for "${component}")"

        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY RUN] Would upgrade ${component} in namespace ${target_ns}"
            if [[ ${#values_args[@]} -gt 0 ]]; then
                log_info "[DRY RUN]   with values: ${values_args[*]}"
            fi
            continue
        fi

        local chart_file
        chart_file="$(find "${charts_dir}" -name "${component}-*.tgz" -type f 2>/dev/null | head -1)"

        if [[ -z "${chart_file}" ]]; then
            log_warn "Chart not found for ${component} — skipping"
            continue
        fi

        log_info "Upgrading ${component} in namespace ${target_ns}"
        helm upgrade --install "${component}" "${chart_file}" \
            --namespace "${target_ns}" \
            --set "global.registry=${registry_url}" \
            --set "global.airgapped=true" \
            "${values_args[@]+"${values_args[@]}"}" \
            --wait \
            --timeout 300s

        log_info "${component} upgraded successfully"
    done < <(components_to_upgrade)
}

###############################################################################
# Phase 5: Health checks and auto-rollback
###############################################################################

# shellcheck disable=SC2317  # return after trigger_rollback is defensive; trigger_rollback exits
phase_health_check() {
    log_info "=== Phase 5: Post-upgrade health checks ==="

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
            log_error "Health check FAILED"
            trigger_rollback
            return 1
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
    done < <(components_to_upgrade)

    if [[ "${exit_ok}" == false ]]; then
        log_error "Health check FAILED"
        trigger_rollback
        return 1
    fi

    log_info "Health check PASSED"
}

###############################################################################
# Auto-rollback on failure
###############################################################################

trigger_rollback() {
    log_warn "=== Auto-rollback triggered ==="

    local rollback_script="${SCRIPT_DIR}/rollback.sh"
    if [[ -x "${rollback_script}" ]]; then
        local rollback_args=(
            --namespace "${NAMESPACE}"
            --operator-namespace "${OPERATOR_NAMESPACE}"
        )
        if [[ -n "${COMPONENT}" ]]; then
            rollback_args+=(--component "${COMPONENT}")
        fi
        if [[ "${VERBOSE}" == true ]]; then
            rollback_args+=(--verbose)
        fi

        log_info "Executing rollback: ${rollback_script} ${rollback_args[*]}"
        if bash "${rollback_script}" "${rollback_args[@]}"; then
            log_info "Rollback completed successfully"
        else
            log_error "Rollback ALSO FAILED — manual intervention required"
        fi
    else
        # Inline rollback using saved revisions
        log_info "rollback.sh not found — performing inline Helm rollback"
        local component
        while IFS= read -r component; do
            local target_ns
            target_ns="$(namespace_for "${component}")"
            local rev_file="${BACKUP_DIR:-}/${component}-revision.txt"

            if [[ -f "${rev_file}" ]]; then
                local prev_rev
                prev_rev="$(cat "${rev_file}")"
                log_info "Rolling back ${component} to revision ${prev_rev}"
                helm rollback "${component}" "${prev_rev}" \
                    -n "${target_ns}" --wait --timeout 300s || \
                    log_error "Failed to rollback ${component}"
            else
                log_warn "No saved revision for ${component} — rolling back to previous"
                helm rollback "${component}" 0 \
                    -n "${target_ns}" --wait --timeout 300s || \
                    log_error "Failed to rollback ${component}"
            fi
        done < <(components_to_upgrade)
    fi

    log_error "Upgrade failed — rollback was triggered"
    exit 3
}

###############################################################################
# Dry-run summary
###############################################################################

print_dry_run_summary() {
    echo ""
    echo "=== UPGRADE PLAN ==="
    echo "Bundle:              ${BUNDLE}"
    echo "Namespace:           ${NAMESPACE}"
    echo "Registry namespace:  ${REGISTRY_NAMESPACE}"
    echo "Operator namespace:  ${OPERATOR_NAMESPACE}"
    echo "Skip backup:         ${SKIP_BACKUP}"
    echo "Custom values:       ${VALUES_FILE:-none}"
    echo "Component filter:    ${COMPONENT:-all}"
    echo ""
    echo "Components to upgrade:"
    local component
    while IFS= read -r component; do
        echo "  - ${component} (namespace: $(namespace_for "${component}"))"
    done < <(components_to_upgrade)
    echo ""
    echo "Phases:"
    echo "  1. Validate bundle (unpack + SHA256 checksum)"
    if [[ "${SKIP_BACKUP}" != true ]]; then
        echo "  2. Backup current Helm release values"
    else
        echo "  2. (skipped) Backup Helm release values"
    fi
    echo "  3. Load new images into registry (crane push)"
    echo "  4. Helm upgrade --install with --wait"
    echo "  5. Post-upgrade health checks (auto-rollback on failure)"
    echo ""
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        log_debug "Cleaning up working directory"
        rm -rf "${WORK_DIR}"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    # Initialise log file
    LOG_FILE="upgrade-$(date -u '+%Y%m%dT%H%M%SZ').log"
    log_info "=== RUNE Air-Gapped Upgrade ==="
    log_info "Bundle: ${BUNDLE}"
    log_info "Log file: ${LOG_FILE}"
    log_debug "Namespace: ${NAMESPACE}, Registry: ${REGISTRY_NAMESPACE}, Operator: ${OPERATOR_NAMESPACE}"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run_summary
    fi

    # Create working directory
    WORK_DIR="$(mktemp -d -t rune-upgrade-XXXXXX)"
    trap cleanup EXIT
    BUNDLE_DIR=""  # Set by phase_validate_bundle

    # Execute phases
    phase_validate_bundle
    phase_backup
    phase_load_images
    phase_helm_upgrade
    phase_health_check

    log_info "=== RUNE upgrade complete ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "=== DRY RUN complete (no changes made) ==="
    else
        echo ""
        echo "RUNE has been upgraded successfully."
        echo "  Namespace: ${NAMESPACE}"
        echo "  Log:       ${LOG_FILE}"
        if [[ -n "${BACKUP_DIR}" ]]; then
            echo "  Backup:    ${BACKUP_DIR}"
        fi
    fi
}

main "$@"
