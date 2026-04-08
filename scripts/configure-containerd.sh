#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# configure-containerd.sh — Configure containerd to use a local zot registry as
# mirror for upstream container registries. Intended for air-gapped nodes where
# all images must be pulled from an in-cluster or on-host registry.
#
# Usage:
#   ./scripts/configure-containerd.sh \
#     --registry-url http://zot.rune-registry.svc.cluster.local:5000
#
# Dependencies: bash, sed, systemctl (optional)
# Exit codes: 0 success, 1 error, 2 not root

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

###############################################################################
# Defaults
###############################################################################

REGISTRY_URL=""
CONFIG_PATH="/etc/containerd/config.toml"
DRY_RUN=false
VERBOSE=false
RESTART=true
BACKUP=true
MIRRORS="docker.io,ghcr.io,registry.k8s.io"

###############################################################################
# Logging
###############################################################################

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >&2
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

Configure containerd to mirror upstream registries through a local zot registry.

Required:
  --registry-url URL         URL of the local zot registry (e.g. http://localhost:5000)

Optional:
  --config-path PATH         Path to containerd config.toml (default: /etc/containerd/config.toml)
  --mirrors LIST             Comma-separated upstream registries to mirror
                             (default: docker.io,ghcr.io,registry.k8s.io)
  --restart                  Restart containerd after config change (default: true)
  --no-restart               Do not restart containerd after config change
  --backup                   Backup original config before modifying (default: true)
  --no-backup                Do not backup original config
  --dry-run                  Show what would be changed without modifying files
  --verbose                  Enable verbose output
  -h, --help                 Show this help message

Exit codes:
  0  Configuration applied successfully
  1  Error during configuration
  2  Not running as root (or with sudo)
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --registry-url)   REGISTRY_URL="$2"; shift 2 ;;
            --config-path)    CONFIG_PATH="$2"; shift 2 ;;
            --mirrors)        MIRRORS="$2"; shift 2 ;;
            --restart)        RESTART=true; shift ;;
            --no-restart)     RESTART=false; shift ;;
            --backup)         BACKUP=true; shift ;;
            --no-backup)      BACKUP=false; shift ;;
            --dry-run)        DRY_RUN=true; shift ;;
            --verbose)        VERBOSE=true; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${REGISTRY_URL}" ]]; then
        log_error "--registry-url is required"
        usage
        exit 1
    fi
}

###############################################################################
# Root check
###############################################################################

require_root() {
    if [[ "${DRY_RUN}" == true ]]; then
        log_debug "Skipping root check in dry-run mode"
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root (or with sudo)"
        exit 2
    fi
}

###############################################################################
# Generate mirror config snippet
###############################################################################

generate_mirror_config() {
    local registry_url="$1"
    local mirrors_csv="$2"

    # Strip trailing slash from registry URL
    registry_url="${registry_url%/}"

    local snippet=""

    # containerd v2 / v1.6+ mirror config format using config_path hosts.toml
    # We generate the [plugins."io.containerd.grpc.v1.cri".registry.mirrors] section
    IFS=',' read -ra mirror_list <<< "${mirrors_csv}"
    for upstream in "${mirror_list[@]}"; do
        upstream="$(echo "${upstream}" | xargs)"  # trim whitespace
        snippet+="
[plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${upstream}\"]
  endpoint = [\"${registry_url}\"]
"
    done

    echo "${snippet}"
}

###############################################################################
# Backup config
###############################################################################

backup_config() {
    local config_file="$1"

    if [[ ! -f "${config_file}" ]]; then
        log_debug "No existing config to backup: ${config_file}"
        return 0
    fi

    local backup_file="${config_file}.bak"
    cp "${config_file}" "${backup_file}"
    log_info "Backed up ${config_file} to ${backup_file}"
}

###############################################################################
# Apply config
###############################################################################

apply_config() {
    local config_file="$1"
    local snippet="$2"

    local config_dir
    config_dir="$(dirname "${config_file}")"

    if [[ ! -d "${config_dir}" ]]; then
        log_info "Creating config directory: ${config_dir}"
        mkdir -p "${config_dir}"
    fi

    if [[ ! -f "${config_file}" ]]; then
        log_info "Creating new config file: ${config_file}"
        echo "# containerd configuration — generated by ${SCRIPT_NAME}" > "${config_file}"
    fi

    # Check whether mirror config already exists
    if grep -q 'registry.mirrors' "${config_file}" 2>/dev/null; then
        log_warn "Existing registry.mirrors section found in ${config_file}"
        log_warn "Appending new mirror entries — review for duplicates"
    fi

    # Append the mirror snippet
    echo "${snippet}" >> "${config_file}"
    log_info "Mirror configuration written to ${config_file}"
}

###############################################################################
# Restart containerd
###############################################################################

restart_containerd() {
    log_info "Restarting containerd"
    systemctl restart containerd

    # Verify containerd is running
    sleep 2
    if systemctl is-active --quiet containerd; then
        log_info "containerd is running"
    else
        log_error "containerd failed to restart"
        exit 1
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"
    require_root

    log_info "=== Containerd Mirror Configuration ==="
    log_info "Registry URL: ${REGISTRY_URL}"
    log_info "Config path:  ${CONFIG_PATH}"
    log_info "Mirrors:      ${MIRRORS}"
    log_debug "Restart: ${RESTART}, Backup: ${BACKUP}, Dry-run: ${DRY_RUN}"

    # Generate config snippet
    local snippet
    snippet="$(generate_mirror_config "${REGISTRY_URL}" "${MIRRORS}")"

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would write the following to ${CONFIG_PATH}:"
        echo "${snippet}"
        if [[ "${BACKUP}" == true && -f "${CONFIG_PATH}" ]]; then
            log_info "[DRY RUN] Would backup ${CONFIG_PATH} to ${CONFIG_PATH}.bak"
        fi
        if [[ "${RESTART}" == true ]]; then
            log_info "[DRY RUN] Would restart containerd"
        fi
        log_info "[DRY RUN] No changes made"
        return 0
    fi

    # Backup
    if [[ "${BACKUP}" == true ]]; then
        backup_config "${CONFIG_PATH}"
    fi

    # Apply
    apply_config "${CONFIG_PATH}" "${snippet}"

    # Restart
    if [[ "${RESTART}" == true ]]; then
        restart_containerd
    else
        log_info "Skipping containerd restart (--no-restart)"
        log_warn "Run 'systemctl restart containerd' to apply changes"
    fi

    log_info "=== Configuration complete ==="
}

main "$@"
