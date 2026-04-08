#!/usr/bin/env bash
# verify-signatures.sh — Offline cosign verification for RUNE air-gapped bundles
#
# IEC 62443 SM-9:  Provenance verification without network access.
# IEC 62443 SM-10: Fail-closed — unsigned/tampered images block deployment.
# IEC 62443 DM-4:  Audit log for compliance evidence.
#
# Usage:
#   ./scripts/verify-signatures.sh --bundle /path/to/unpacked --key cosign.pub
#   ./scripts/verify-signatures.sh --bundle /path/to/unpacked --key cosign.pub --dry-run
#   ./scripts/verify-signatures.sh --bundle /path/to/unpacked --key cosign.pub --registry localhost:5000
#
# Exit codes:
#   0 — All images verified successfully
#   1 — Usage error or missing dependencies
#   2 — One or more images failed verification
#   3 — Verification blocked deployment (used by bootstrap.sh)
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly LOG_DIR="/var/log/rune-airgapped"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly TIMESTAMP
readonly AUDIT_LOG="${LOG_DIR}/verify-${TIMESTAMP}.log"

# ── Defaults ───────────────────────────────────────────────────────
BUNDLE_DIR=""
PUBLIC_KEY=""
REGISTRY="rune-registry.rune-registry.svc:5000"
DRY_RUN=false
COSIGN_BIN=""

# RUNE images to verify
RUNE_IMAGES=(
    "rune"
    "rune-operator"
    "rune-ui"
    "rune-docs"
    "rune-audit"
)

# ── Functions ──────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} --bundle <dir> --key <cosign.pub> [OPTIONS]

Verify cosign signatures on all RUNE images in an air-gapped bundle.

Required:
  --bundle <dir>       Path to unpacked bundle directory
  --key <file>         Path to cosign public key (cosign.pub)

Options:
  --registry <host>    Registry address (default: rune-registry.rune-registry.svc:5000)
  --cosign <path>      Path to cosign binary (default: <bundle>/tools/cosign)
  --dry-run            List images that would be verified; do not execute cosign
  --help               Show this help message

Exit codes:
  0  All images verified
  1  Usage error or missing dependency
  2  Verification failure (one or more images)
  3  Deployment blocked (called from bootstrap)
EOF
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" | tee -a "${AUDIT_LOG}" 2>/dev/null || \
        printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_pass()  { log "PASS"  "$@"; }
log_fail()  { log "FAIL"  "$@"; }

init_audit_log() {
    if mkdir -p "${LOG_DIR}" 2>/dev/null; then
        log_info "Audit log: ${AUDIT_LOG}"
    else
        log_warn "Cannot create ${LOG_DIR} — logging to stdout only"
    fi
    log_info "=== RUNE Image Signature Verification ==="
    log_info "Bundle: ${BUNDLE_DIR}"
    log_info "Public key: ${PUBLIC_KEY}"
    log_info "Registry: ${REGISTRY}"
    log_info "Dry run: ${DRY_RUN}"
}

find_cosign() {
    if [[ -n "${COSIGN_BIN}" ]]; then
        if [[ ! -x "${COSIGN_BIN}" ]]; then
            log_error "Specified cosign binary not found or not executable: ${COSIGN_BIN}"
            exit 1
        fi
        return
    fi

    # Look in bundle first
    if [[ -x "${BUNDLE_DIR}/tools/cosign" ]]; then
        COSIGN_BIN="${BUNDLE_DIR}/tools/cosign"
        log_info "Using bundled cosign: ${COSIGN_BIN}"
        return
    fi

    # Fall back to PATH
    if command -v cosign >/dev/null 2>&1; then
        COSIGN_BIN="$(command -v cosign)"
        log_info "Using system cosign: ${COSIGN_BIN}"
        return
    fi

    log_error "cosign binary not found. Bundle it under <bundle>/tools/cosign or install it."
    exit 1
}
# shellcheck disable=SC2329

discover_images() {
    local manifest_file="${BUNDLE_DIR}/manifest.json"
    if [[ -f "${manifest_file}" ]]; then
        # If a manifest.json exists, extract image references from it
        log_info "Discovering images from ${manifest_file}"
        # Use python3 for JSON parsing (available on most systems)
        python3 -c "
import json, sys
with open('${manifest_file}') as f:
    data = json.load(f)
images = data.get('images', [])
for img in images:
    print(img.get('name', ''))
" 2>/dev/null && return
    fi

    # Fall back to known RUNE image list
    log_info "Using default RUNE image list"
}

verify_image() {
    local image_ref="$1"
    local full_ref="${REGISTRY}/${image_ref}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would verify: ${full_ref}"
        return 0
    fi

    log_info "Verifying: ${full_ref}"

    # --insecure-ignore-tlog=true: Rekor transparency log is unreachable in air-gapped
    # --insecure-ignore-sct=true: SCT verification requires Fulcio CT log (unreachable)
    if "${COSIGN_BIN}" verify \
        --key "${PUBLIC_KEY}" \
        --insecure-ignore-tlog=true \
        --insecure-ignore-sct=true \
        "${full_ref}" 2>&1 | tee -a "${AUDIT_LOG}" 2>/dev/null; then
        log_pass "VERIFIED: ${full_ref}"
        return 0
    else
        log_fail "FAILED: ${full_ref}"
        return 1
    fi
}

# ── Argument parsing ───────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bundle)
                BUNDLE_DIR="$2"
                shift 2
                ;;
            --key)
                PUBLIC_KEY="$2"
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --cosign)
                COSIGN_BIN="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "${BUNDLE_DIR}" ]]; then
        log_error "--bundle is required"
        usage
        exit 1
    fi

    if [[ -z "${PUBLIC_KEY}" ]]; then
        log_error "--key is required"
        usage
        exit 1
    fi

    if [[ ! -d "${BUNDLE_DIR}" ]]; then
        log_error "Bundle directory does not exist: ${BUNDLE_DIR}"
        exit 1
    fi

    if [[ ! -f "${PUBLIC_KEY}" ]]; then
        log_error "Public key file does not exist: ${PUBLIC_KEY}"
        exit 1
    fi
}

# ── Main ───────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    init_audit_log

    if [[ "${DRY_RUN}" != "true" ]]; then
        find_cosign
        log_info "cosign version: $(${COSIGN_BIN} version 2>&1 | head -1 || echo 'unknown')"
    fi

    local total=0
    local passed=0
    local failed=0
    local failed_images=()

    # Discover images from manifest or use defaults
    local images=()
    local manifest_file="${BUNDLE_DIR}/manifest.json"
    if [[ -f "${manifest_file}" ]]; then
        while IFS= read -r img; do
            [[ -n "${img}" ]] && images+=("${img}")
        done < <(python3 -c "
import json
with open('${manifest_file}') as f:
    data = json.load(f)
for img in data.get('images', []):
    name = img.get('name', '')
    if name:
        print(name)
" 2>/dev/null)
    fi

    # Fall back to default image list if no manifest
    if [[ ${#images[@]} -eq 0 ]]; then
        images=("${RUNE_IMAGES[@]}")
    fi

    log_info "Images to verify: ${#images[@]}"
    log_info "---"

    for image in "${images[@]}"; do
        total=$((total + 1))
        if verify_image "${image}"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            failed_images+=("${image}")
        fi
    done

    # ── Summary ────────────────────────────────────────────────────
    log_info "=== Verification Summary ==="
    log_info "Total:  ${total}"
    log_info "Passed: ${passed}"
    log_info "Failed: ${failed}"

    if [[ ${failed} -gt 0 ]]; then
        log_error "Failed images:"
        for img in "${failed_images[@]}"; do
            log_error "  - ${img}"
        done
        log_error "DEPLOYMENT BLOCKED: ${failed} image(s) failed signature verification"
        exit 2
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "Dry run complete. No images were actually verified."
    else
        log_pass "All ${total} images verified successfully."
    fi

    exit 0
}

main "$@"
