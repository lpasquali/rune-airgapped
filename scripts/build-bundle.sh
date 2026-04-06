#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# build-bundle.sh — Build an OCI bundle for air-gapped RUNE deployment.
#
# Produces a single distributable tarball containing all container images,
# Helm charts, compliance artifacts, and integrity checksums required to
# deploy RUNE in an air-gapped environment.
#
# Usage:
#   ./scripts/build-bundle.sh \
#     --tag v0.0.0a2 \
#     --output rune-bundle-v0.0.0a2.tar.gz \
#     --arch amd64,arm64 \
#     --include-ollama \
#     --sign
#
# Dependencies: crane, helm, cosign (optional), sha256sum, tar
# Exit codes: 0 success, 1 error

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

# RUNE container images (GHCR)
readonly -a RUNE_IMAGES=(
    "ghcr.io/lpasquali/rune"
    "ghcr.io/lpasquali/rune-operator"
    "ghcr.io/lpasquali/rune-ui"
    "ghcr.io/lpasquali/rune-docs"
    "ghcr.io/lpasquali/rune-audit"
)

# Infrastructure images
readonly -a INFRA_IMAGES=(
    "docker.io/library/nginx:1.27.4-alpine"
    "ghcr.io/project-zot/zot-linux-amd64:v2.1.2"
)

# Optional images (added via flags)
readonly OLLAMA_IMAGE="docker.io/ollama/ollama:latest"
readonly SEAWEEDFS_IMAGE="docker.io/chrislusf/seaweedfs:latest"

# Helm charts (OCI artifacts from rune-charts)
readonly -a HELM_CHARTS=(
    "rune"
    "rune-operator"
    "rune-ui"
)
readonly HELM_CHART_REGISTRY="ghcr.io/lpasquali/rune-charts"

###############################################################################
# Defaults
###############################################################################

TAG=""
OUTPUT=""
ARCH="amd64,arm64"
INCLUDE_OLLAMA=false
INCLUDE_SEAWEEDFS=false
SIGN=false
DRY_RUN=false
COSIGN_KEY=""
WORK_DIR=""
VERBOSE=false

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

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Build an OCI bundle for air-gapped RUNE deployment.

Required:
  --tag TAG              RUNE version tag (e.g. v0.0.0a2)
  --output FILE          Output tarball path (e.g. rune-bundle-v0.0.0a2.tar.gz)

Optional:
  --arch ARCH            Target architectures, comma-separated (default: amd64,arm64)
  --include-ollama       Include Ollama inference server image
  --include-seaweedfs    Include SeaweedFS S3-compatible storage image
  --sign                 Sign images with cosign (requires COSIGN_KEY env var)
  --cosign-key FILE      Path to cosign private key (alternative to COSIGN_KEY env)
  --dry-run              List what would be bundled without pulling anything
  --verbose              Enable verbose output
  -h, --help             Show this help message

Environment:
  COSIGN_KEY             Path to cosign private key (used with --sign)

Exit codes:
  0  Success
  1  Error
EOF
}

###############################################################################
# Argument parsing
###############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag)        TAG="$2"; shift 2 ;;
            --output)     OUTPUT="$2"; shift 2 ;;
            --arch)       ARCH="$2"; shift 2 ;;
            --include-ollama)    INCLUDE_OLLAMA=true; shift ;;
            --include-seaweedfs) INCLUDE_SEAWEEDFS=true; shift ;;
            --sign)       SIGN=true; shift ;;
            --cosign-key) COSIGN_KEY="$2"; shift 2 ;;
            --dry-run)    DRY_RUN=true; shift ;;
            --verbose)    VERBOSE=true; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    if [[ -z "${TAG}" ]]; then
        log_error "--tag is required"
        usage
        exit 1
    fi

    if [[ -z "${OUTPUT}" ]]; then
        log_error "--output is required"
        usage
        exit 1
    fi

    if [[ "${SIGN}" == true && "${DRY_RUN}" != true ]]; then
        COSIGN_KEY="${COSIGN_KEY:-${COSIGN_KEY_ENV:-}}"
        if [[ -z "${COSIGN_KEY}" ]]; then
            log_error "--sign requires --cosign-key or COSIGN_KEY env var"
            exit 1
        fi
        if [[ ! -f "${COSIGN_KEY}" ]]; then
            log_error "Cosign key not found: ${COSIGN_KEY}"
            exit 1
        fi
    fi
}

###############################################################################
# Prerequisite checks
###############################################################################

check_prerequisites() {
    local missing=()

    for cmd in crane tar sha256sum; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ "${SIGN}" == true ]] && ! command -v cosign &>/dev/null; then
        missing+=("cosign")
    fi

    if ! command -v helm &>/dev/null; then
        missing+=("helm")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}

###############################################################################
# Image list builder
###############################################################################

build_image_list() {
    local images=()

    # RUNE images with tag
    for img in "${RUNE_IMAGES[@]}"; do
        images+=("${img}:${TAG}")
    done

    # Infrastructure images (already have tags)
    for img in "${INFRA_IMAGES[@]}"; do
        images+=("$img")
    done

    # Optional images
    if [[ "${INCLUDE_OLLAMA}" == true ]]; then
        images+=("${OLLAMA_IMAGE}")
    fi

    if [[ "${INCLUDE_SEAWEEDFS}" == true ]]; then
        images+=("${SEAWEEDFS_IMAGE}")
    fi

    printf '%s\n' "${images[@]}"
}

###############################################################################
# Dry-run mode
###############################################################################

do_dry_run() {
    log_info "=== DRY RUN: listing bundle contents ==="
    echo ""
    echo "Bundle: ${OUTPUT}"
    echo "Tag:    ${TAG}"
    echo "Arch:   ${ARCH}"
    echo ""

    echo "=== Container Images ==="
    local images
    images="$(build_image_list)"
    while IFS= read -r img; do
        echo "  - ${img}"
    done <<< "${images}"
    echo ""

    echo "=== Helm Charts ==="
    for chart in "${HELM_CHARTS[@]}"; do
        echo "  - ${HELM_CHART_REGISTRY}/${chart}:${TAG}"
    done
    echo ""

    echo "=== Compliance Artifacts ==="
    echo "  - compliance/sboms/ (CycloneDX SBOM per image)"
    echo "  - compliance/vex/ (aggregated VEX documents)"
    echo "  - compliance/attestations/ (SLSA provenance per image)"
    echo ""

    if [[ "${SIGN}" == true ]]; then
        echo "=== Signing ==="
        echo "  - Images will be cosign-signed"
        echo "  - cosign.pub will be included in bundle"
        echo ""
    fi

    echo "=== Integrity ==="
    echo "  - manifest.json (machine-readable manifest with digests)"
    echo "  - SHA256SUMS (integrity checksums for all files)"
    echo ""

    log_info "=== DRY RUN complete (no changes made) ==="
}

###############################################################################
# Pull images as OCI layout
###############################################################################

pull_images() {
    local staging_dir="$1"
    local images_dir="${staging_dir}/images"
    mkdir -p "${images_dir}"

    local images
    images="$(build_image_list)"

    IFS=',' read -ra arch_list <<< "${ARCH}"

    while IFS= read -r img; do
        local img_name
        img_name="$(echo "${img}" | sed 's|.*/||; s|:.*||')"
        local img_dir="${images_dir}/${img_name}"
        mkdir -p "${img_dir}"

        log_info "Pulling image: ${img}"

        for arch in "${arch_list[@]}"; do
            local platform="linux/${arch}"
            local layout_dir="${img_dir}/${arch}"
            mkdir -p "${layout_dir}"

            if [[ "${VERBOSE}" == true ]]; then
                log_info "  Platform: ${platform}"
            fi

            if ! crane pull "${img}" "${layout_dir}" --platform "${platform}" --format oci 2>&1; then
                log_warn "Failed to pull ${img} for ${platform} (may not exist yet)"
            fi
        done
    done <<< "${images}"

    log_info "Image pull complete"
}

###############################################################################
# Pull Helm charts
###############################################################################

pull_charts() {
    local staging_dir="$1"
    local charts_dir="${staging_dir}/charts"
    mkdir -p "${charts_dir}"

    for chart in "${HELM_CHARTS[@]}"; do
        local chart_ref="oci://${HELM_CHART_REGISTRY}/${chart}"
        log_info "Pulling Helm chart: ${chart_ref} version ${TAG}"

        if ! helm pull "${chart_ref}" --version "${TAG}" --destination "${charts_dir}" 2>&1; then
            log_warn "Failed to pull chart ${chart} version ${TAG} (may not exist yet)"
        fi
    done

    log_info "Helm chart pull complete"
}

###############################################################################
# Collect compliance artifacts
###############################################################################

collect_compliance_artifacts() {
    local staging_dir="$1"
    local compliance_dir="${staging_dir}/compliance"
    mkdir -p "${compliance_dir}/sboms"
    mkdir -p "${compliance_dir}/vex"
    mkdir -p "${compliance_dir}/attestations"

    # Collect VEX documents from the repo
    if [[ -d "${REPO_ROOT}/.vex" ]]; then
        log_info "Collecting VEX documents from repo"
        find "${REPO_ROOT}/.vex" -name '*.json' -exec cp {} "${compliance_dir}/vex/" \; 2>/dev/null || true
    fi

    # Placeholder for SBOMs and attestations (collected from CI artifacts)
    log_info "Compliance artifact directories created (SBOMs/attestations populated by CI)"
}

###############################################################################
# Sign images
###############################################################################

sign_images() {
    local staging_dir="$1"

    if [[ "${SIGN}" != true ]]; then
        log_info "Skipping image signing (--sign not specified)"
        return 0
    fi

    local signatures_dir="${staging_dir}/signatures"
    mkdir -p "${signatures_dir}"

    log_info "Signing images with cosign"

    local images
    images="$(build_image_list)"

    while IFS= read -r img; do
        log_info "Signing: ${img}"
        if ! cosign sign --key "${COSIGN_KEY}" "${img}" 2>&1; then
            log_warn "Failed to sign ${img}"
        fi
    done <<< "${images}"

    # Export public key
    local pub_key="${COSIGN_KEY%.key}.pub"
    if [[ -f "${pub_key}" ]]; then
        cp "${pub_key}" "${staging_dir}/cosign.pub"
        log_info "Included cosign.pub in bundle"
    else
        log_warn "Public key not found at ${pub_key}"
    fi

    log_info "Image signing complete"
}

###############################################################################
# Generate manifest.json
###############################################################################

generate_manifest() {
    local staging_dir="$1"
    local manifest_file="${staging_dir}/manifest.json"

    log_info "Generating manifest.json"

    local images_json="[]"
    local charts_json="[]"

    # Collect image entries
    if [[ -d "${staging_dir}/images" ]]; then
        local img_entries=()
        while IFS= read -r img_dir; do
            local img_name
            img_name="$(basename "${img_dir}")"
            img_entries+=("{\"name\":\"${img_name}\",\"path\":\"images/${img_name}\"}")
        done < <(find "${staging_dir}/images" -mindepth 1 -maxdepth 1 -type d | sort)

        if [[ ${#img_entries[@]} -gt 0 ]]; then
            images_json="[$(IFS=,; echo "${img_entries[*]}")]"
        fi
    fi

    # Collect chart entries
    if [[ -d "${staging_dir}/charts" ]]; then
        local chart_entries=()
        while IFS= read -r chart_file; do
            local chart_name
            chart_name="$(basename "${chart_file}")"
            local chart_sha
            chart_sha="$(sha256sum "${chart_file}" | awk '{print $1}')"
            chart_entries+=("{\"name\":\"${chart_name}\",\"path\":\"charts/${chart_name}\",\"sha256\":\"${chart_sha}\"}")
        done < <(find "${staging_dir}/charts" -name '*.tgz' -type f | sort)

        if [[ ${#chart_entries[@]} -gt 0 ]]; then
            charts_json="[$(IFS=,; echo "${chart_entries[*]}")]"
        fi
    fi

    cat > "${manifest_file}" <<MANIFEST_EOF
{
    "version": "${TAG}",
    "arch": "${ARCH}",
    "created": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "images": ${images_json},
    "charts": ${charts_json},
    "signed": ${SIGN}
}
MANIFEST_EOF

    log_info "manifest.json generated"
}

###############################################################################
# Generate SHA256SUMS
###############################################################################

generate_checksums() {
    local staging_dir="$1"
    local sums_file="${staging_dir}/SHA256SUMS"

    log_info "Generating SHA256SUMS"

    (
        cd "${staging_dir}"
        find . -type f ! -name 'SHA256SUMS' -print0 \
            | sort -z \
            | xargs -0 sha256sum \
            | sed 's|  \./|  |'
    ) > "${sums_file}"

    local count
    count="$(wc -l < "${sums_file}")"
    log_info "SHA256SUMS generated (${count} entries)"
}

###############################################################################
# Package tarball
###############################################################################

package_tarball() {
    local staging_dir="$1"
    local output_file="$2"

    log_info "Packaging tarball: ${output_file}"

    # Use deterministic tar options for reproducibility
    tar \
        --sort=name \
        --mtime="2026-01-01T00:00:00Z" \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        -czf "${output_file}" \
        -C "$(dirname "${staging_dir}")" \
        "$(basename "${staging_dir}")"

    local size
    size="$(du -h "${output_file}" | awk '{print $1}')"
    log_info "Bundle created: ${output_file} (${size})"
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        log_info "Cleaning up staging directory"
        rm -rf "${WORK_DIR}"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    log_info "=== RUNE OCI Bundle Builder ==="
    log_info "Tag: ${TAG}, Arch: ${ARCH}, Output: ${OUTPUT}"

    if [[ "${DRY_RUN}" == true ]]; then
        do_dry_run
        exit 0
    fi

    check_prerequisites

    # Create staging directory
    WORK_DIR="$(mktemp -d -t rune-bundle-XXXXXX)"
    trap cleanup EXIT

    local staging_dir="${WORK_DIR}/rune-bundle-${TAG}"
    mkdir -p "${staging_dir}"

    # Create bundle structure
    mkdir -p "${staging_dir}/scripts"
    mkdir -p "${staging_dir}/manifests"
    mkdir -p "${staging_dir}/values"

    # Phase 1: Pull images
    pull_images "${staging_dir}"

    # Phase 2: Pull Helm charts
    pull_charts "${staging_dir}"

    # Phase 3: Collect compliance artifacts
    collect_compliance_artifacts "${staging_dir}"

    # Phase 4: Sign images (if requested)
    sign_images "${staging_dir}"

    # Phase 5: Generate manifest
    generate_manifest "${staging_dir}"

    # Phase 6: Generate checksums (must be last before packaging)
    generate_checksums "${staging_dir}"

    # Phase 7: Package tarball
    package_tarball "${staging_dir}" "${OUTPUT}"

    log_info "=== Bundle build complete ==="
}

main "$@"
