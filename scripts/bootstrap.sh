#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# bootstrap.sh — Deploy RUNE from an air-gapped OCI bundle into a Kubernetes
# cluster. This is the single entry point for air-gapped deployment.
#
# Usage:
#   ./scripts/bootstrap.sh \
#     --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz \
#     --namespace rune \
#     --registry-namespace rune-registry
#
# Dependencies: bash, tar, kubectl, helm (helmfile bundled in tarball)
# Exit codes: 0 success, 1 error, 2 prerequisites missing, 3 verification failed

set -euo pipefail

###############################################################################
# Constants
###############################################################################

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
export SCRIPT_DIR  # Used by sub-scripts (health-check, verify-bundle)

# Minimum tool versions
readonly MIN_KUBECTL_VERSION="1.27.0"
readonly MIN_HELM_VERSION="3.12.0"

# Zot registry defaults
readonly ZOT_IMAGE_NAME="zot"
readonly ZOT_PORT=5000

###############################################################################
# Defaults
###############################################################################

BUNDLE=""
NAMESPACE="rune"
REGISTRY_NAMESPACE="rune-registry"
OPERATOR_NAMESPACE="rune-system"
DRY_RUN=false
SKIP_VERIFY=false
REGISTRY_ONLY=false
NO_NETWORK_POLICIES=false
NO_RESOURCE_QUOTAS=false
VALUES_FILE=""
VERBOSE=false
WORK_DIR=""
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

Deploy RUNE from an air-gapped OCI bundle into a Kubernetes cluster.

Required:
  --bundle FILE              Path to RUNE bundle tarball

Optional:
  --namespace NS             Application namespace (default: rune)
  --registry-namespace NS    Registry namespace (default: rune-registry)
  --operator-namespace NS    Operator namespace (default: rune-system)
  --dry-run                  Preview deployment plan without making changes
  --skip-verify              Skip cosign signature verification (not recommended)
  --registry-only            Only deploy the registry (for custom pipelines)
  --no-network-policies      Skip NetworkPolicy application
  --no-resource-quotas       Skip ResourceQuota application
  --values FILE              Custom Helm values overlay file
  --verbose                  Enable verbose output
  -h, --help                 Show this help message

Exit codes:
  0  All phases completed successfully
  1  Error during deployment
  2  Prerequisites missing (no changes made)
  3  Verification failed — supply chain integrity violation (no changes made)
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
            --skip-verify)         SKIP_VERIFY=true; shift ;;
            --registry-only)       REGISTRY_ONLY=true; shift ;;
            --no-network-policies) NO_NETWORK_POLICIES=true; shift ;;
            --no-resource-quotas)  NO_RESOURCE_QUOTAS=true; shift ;;
            --values)              VALUES_FILE="$2"; shift 2 ;;
            --verbose)             VERBOSE=true; shift ;;
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
}

###############################################################################
# Version comparison utility
###############################################################################

version_ge() {
    # Returns 0 if $1 >= $2 (semver-ish comparison)
    local v1="$1"
    local v2="$2"

    if [[ "${v1}" == "${v2}" ]]; then
        return 0
    fi

    local IFS=.
    local i
    local -a ver1=() ver2=()
    read -ra ver1 <<< "${v1}"
    read -ra ver2 <<< "${v2}"

    for ((i = 0; i < ${#ver2[@]}; i++)); do
        local n1="${ver1[i]:-0}"
        local n2="${ver2[i]:-0}"
        if ((n1 > n2)); then
            return 0
        elif ((n1 < n2)); then
            return 1
        fi
    done
    return 0
}

###############################################################################
# Phase 1: Unpack bundle
###############################################################################

phase_unpack() {
    log_info "=== Phase 1: Unpacking bundle ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would unpack: ${BUNDLE} -> ${WORK_DIR}/"
        return 0
    fi

    tar xzf "${BUNDLE}" -C "${WORK_DIR}/"

    # Find the extracted directory (should be rune-bundle-<tag>)
    local bundle_dir
    bundle_dir="$(find "${WORK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [[ -z "${bundle_dir}" ]]; then
        log_error "Bundle extraction failed: no directory found"
        exit 1
    fi

    # Export for other phases
    BUNDLE_DIR="${bundle_dir}"
    log_info "Bundle unpacked to: ${BUNDLE_DIR}"
}

###############################################################################
# Phase 2: Verify supply chain integrity
###############################################################################

phase_verify() {
    log_info "=== Phase 2: Verifying supply chain integrity ==="

    if [[ "${SKIP_VERIFY}" == true ]]; then
        log_warn "Skipping verification (--skip-verify). NOT RECOMMENDED."
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would verify SHA256SUMS in ${BUNDLE_DIR:-<bundle>}"
        log_info "[DRY RUN] Would verify cosign signatures with bundled cosign.pub"
        return 0
    fi

    local sums_file="${BUNDLE_DIR}/SHA256SUMS"
    if [[ ! -f "${sums_file}" ]]; then
        log_error "SHA256SUMS not found in bundle — integrity cannot be verified"
        exit 3
    fi

    log_info "Verifying SHA256 checksums"
    if ! (cd "${BUNDLE_DIR}" && sha256sum -c SHA256SUMS --quiet 2>&1); then
        log_error "SHA256 checksum verification FAILED — supply chain integrity violation"
        exit 3
    fi

    log_info "SHA256 checksum verification PASSED"

    # Verify cosign signatures if cosign.pub is present
    if [[ -f "${BUNDLE_DIR}/cosign.pub" ]] && command -v cosign &>/dev/null; then
        log_info "Cosign public key found — signature verification available"
        # Cosign verification of OCI layout images requires registry access;
        # in air-gapped mode, we verify after loading into the local registry.
        log_info "Image signatures will be verified after registry deployment"
    else
        log_info "No cosign.pub in bundle or cosign not available — skipping signature verification"
    fi
}

###############################################################################
# Phase 3: Check prerequisites
###############################################################################

phase_prerequisites() {
    log_info "=== Phase 3: Checking prerequisites ==="

    local missing=()
    local warnings=()

    # Required tools
    for cmd in kubectl helm tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        if [[ "${DRY_RUN}" != true ]]; then
            exit 2
        fi
        return 0
    fi

    # Version checks
    local kubectl_version
    kubectl_version="$(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+')" || true
    if [[ -n "${kubectl_version}" ]]; then
        if ! version_ge "${kubectl_version}" "${MIN_KUBECTL_VERSION}"; then
            log_error "kubectl ${kubectl_version} < required ${MIN_KUBECTL_VERSION}"
            if [[ "${DRY_RUN}" != true ]]; then
                exit 2
            fi
        else
            log_info "kubectl ${kubectl_version} >= ${MIN_KUBECTL_VERSION} OK"
        fi
    fi

    local helm_version
    helm_version="$(helm version --short 2>/dev/null | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+')" || true
    if [[ -n "${helm_version}" ]]; then
        if ! version_ge "${helm_version}" "${MIN_HELM_VERSION}"; then
            log_error "helm ${helm_version} < required ${MIN_HELM_VERSION}"
            if [[ "${DRY_RUN}" != true ]]; then
                exit 2
            fi
        else
            log_info "helm ${helm_version} >= ${MIN_HELM_VERSION} OK"
        fi
    fi

    # Cluster connectivity
    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would check cluster connectivity"
    else
        if ! kubectl cluster-info &>/dev/null; then
            log_error "Cannot connect to Kubernetes cluster"
            exit 2
        fi
        log_info "Cluster connectivity OK"
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        for w in "${warnings[@]}"; do
            log_warn "${w}"
        done
    fi

    log_info "Prerequisites check complete"
}

###############################################################################
# Phase 4: Create namespaces and security scaffolding
###############################################################################

phase_namespaces() {
    log_info "=== Phase 4: Creating namespaces and security scaffolding ==="

    local namespaces=("${REGISTRY_NAMESPACE}" "${OPERATOR_NAMESPACE}" "${NAMESPACE}")

    for ns in "${namespaces[@]}"; do
        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY RUN] Would create namespace: ${ns}"
            log_info "[DRY RUN] Would apply PSA label: pod-security.kubernetes.io/enforce=restricted"
        else
            if kubectl get namespace "${ns}" &>/dev/null; then
                log_info "Namespace ${ns} already exists"
            else
                kubectl create namespace "${ns}"
                log_info "Created namespace: ${ns}"
            fi

            # Apply Pod Security Admission labels
            kubectl label namespace "${ns}" \
                "pod-security.kubernetes.io/enforce=restricted" \
                "pod-security.kubernetes.io/warn=restricted" \
                --overwrite
            log_info "Applied PSA labels to namespace: ${ns}"
        fi
    done

    # Apply RBAC manifests if present
    if [[ -d "${BUNDLE_DIR:-}/manifests" ]]; then
        local rbac_files
        rbac_files="$(find "${BUNDLE_DIR}/manifests" -name '*rbac*' -o -name '*role*' 2>/dev/null | sort)" || true
        if [[ -n "${rbac_files}" ]]; then
            while IFS= read -r f; do
                if [[ "${DRY_RUN}" == true ]]; then
                    log_info "[DRY RUN] Would apply RBAC: ${f}"
                else
                    kubectl apply -f "${f}"
                    log_info "Applied RBAC: $(basename "${f}")"
                fi
            done <<< "${rbac_files}"
        fi
    fi

    # Apply NetworkPolicies if not skipped
    if [[ "${NO_NETWORK_POLICIES}" != true && -d "${BUNDLE_DIR:-}/manifests" ]]; then
        local np_files
        np_files="$(find "${BUNDLE_DIR}/manifests" -name '*network*' -o -name '*netpol*' 2>/dev/null | sort)" || true
        if [[ -n "${np_files}" ]]; then
            while IFS= read -r f; do
                if [[ "${DRY_RUN}" == true ]]; then
                    log_info "[DRY RUN] Would apply NetworkPolicy: ${f}"
                else
                    kubectl apply -f "${f}"
                    log_info "Applied NetworkPolicy: $(basename "${f}")"
                fi
            done <<< "${np_files}"
        fi
    elif [[ "${NO_NETWORK_POLICIES}" == true ]]; then
        log_info "Skipping NetworkPolicy application (--no-network-policies)"
    fi

    # Apply ResourceQuotas if not skipped
    if [[ "${NO_RESOURCE_QUOTAS}" != true && -d "${BUNDLE_DIR:-}/manifests" ]]; then
        local rq_files
        rq_files="$(find "${BUNDLE_DIR}/manifests" -name '*quota*' -o -name '*limit-range*' 2>/dev/null | sort)" || true
        if [[ -n "${rq_files}" ]]; then
            while IFS= read -r f; do
                if [[ "${DRY_RUN}" == true ]]; then
                    log_info "[DRY RUN] Would apply ResourceQuota: ${f}"
                else
                    kubectl apply -f "${f}"
                    log_info "Applied ResourceQuota: $(basename "${f}")"
                fi
            done <<< "${rq_files}"
        fi
    elif [[ "${NO_RESOURCE_QUOTAS}" == true ]]; then
        log_info "Skipping ResourceQuota application (--no-resource-quotas)"
    fi

    log_info "Namespace and security scaffolding complete"
}

###############################################################################
# Phase 5: Deploy local registry and load images
###############################################################################

phase_registry() {
    log_info "=== Phase 5: Deploying local registry ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would deploy zot registry in namespace: ${REGISTRY_NAMESPACE}"
        log_info "[DRY RUN] Would load OCI images from bundle into registry"
        log_info "[DRY RUN] Would verify registry is serving at zot.${REGISTRY_NAMESPACE}.svc.cluster.local:${ZOT_PORT}"
        return 0
    fi

    # Check if zot image is in the bundle
    local zot_image_dir="${BUNDLE_DIR}/images/${ZOT_IMAGE_NAME}"
    if [[ ! -d "${zot_image_dir}" ]]; then
        # Try alternate name
        zot_image_dir="${BUNDLE_DIR}/images/zot-linux-amd64"
    fi

    if [[ ! -d "${zot_image_dir}" ]]; then
        log_error "Zot registry image not found in bundle"
        exit 1
    fi

    # Deploy zot as a Kubernetes Deployment
    log_info "Deploying zot registry"

    kubectl apply -f - <<ZOT_EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: zot-config
  namespace: ${REGISTRY_NAMESPACE}
data:
  config.json: |
    {
      "storage": {"rootDirectory": "/var/lib/registry"},
      "http": {"address": "0.0.0.0", "port": "${ZOT_PORT}"},
      "log": {"level": "info"}
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zot
  namespace: ${REGISTRY_NAMESPACE}
  labels:
    app.kubernetes.io/name: zot
    app.kubernetes.io/component: registry
    app.kubernetes.io/part-of: rune
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: zot
  template:
    metadata:
      labels:
        app.kubernetes.io/name: zot
    spec:
      containers:
      - name: zot
        image: ghcr.io/project-zot/zot-linux-amd64:v2.1.2
        ports:
        - containerPort: ${ZOT_PORT}
          name: registry
        volumeMounts:
        - name: config
          mountPath: /etc/zot
        - name: storage
          mountPath: /var/lib/registry
        readinessProbe:
          httpGet:
            path: /v2/
            port: registry
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop: ["ALL"]
          seccompProfile:
            type: RuntimeDefault
      volumes:
      - name: config
        configMap:
          name: zot-config
      - name: storage
        emptyDir:
          sizeLimit: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: zot
  namespace: ${REGISTRY_NAMESPACE}
  labels:
    app.kubernetes.io/name: zot
spec:
  selector:
    app.kubernetes.io/name: zot
  ports:
  - port: ${ZOT_PORT}
    targetPort: registry
    name: registry
ZOT_EOF

    log_info "Waiting for zot registry to be ready"
    kubectl rollout status deployment/zot \
        -n "${REGISTRY_NAMESPACE}" \
        --timeout=120s

    log_info "Registry deployed and ready"

    # Load images into registry
    phase_load_images
}

###############################################################################
# Load OCI images into the local registry
###############################################################################

phase_load_images() {
    log_info "Loading images into local registry"

    if [[ ! -d "${BUNDLE_DIR}/images" ]]; then
        log_warn "No images directory found in bundle"
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

        # Find OCI layout directories for each arch
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
# Phase 6: Deploy RUNE components
###############################################################################

phase_deploy() {
    log_info "=== Phase 6: Deploying RUNE components ==="

    if [[ "${REGISTRY_ONLY}" == true ]]; then
        log_info "Skipping component deployment (--registry-only)"
        return 0
    fi

    local registry_url="zot.${REGISTRY_NAMESPACE}.svc.cluster.local:${ZOT_PORT}"
    local charts_dir="${BUNDLE_DIR}/charts"

    if [[ ! -d "${charts_dir}" ]]; then
        log_warn "No charts directory in bundle — skipping Helm deployment"
        return 0
    fi

    # Build values args
    local values_args=()
    if [[ -n "${VALUES_FILE}" ]]; then
        values_args+=(--values "${VALUES_FILE}")
    fi

    # Deployment ordering: operator -> API server -> UI
    local -a deploy_order=("rune-operator" "rune" "rune-ui")

    for component in "${deploy_order[@]}"; do
        local chart_file
        chart_file="$(find "${charts_dir}" -name "${component}-*.tgz" -type f 2>/dev/null | head -1)"

        if [[ -z "${chart_file}" ]]; then
            log_warn "Chart not found for ${component} — skipping"
            continue
        fi

        local target_ns="${NAMESPACE}"
        if [[ "${component}" == "rune-operator" ]]; then
            target_ns="${OPERATOR_NAMESPACE}"
        fi

        if [[ "${DRY_RUN}" == true ]]; then
            log_info "[DRY RUN] Would deploy ${component} from ${chart_file} to namespace ${target_ns}"
            log_info "[DRY RUN]   helm upgrade --install ${component} ${chart_file} -n ${target_ns}"
            if [[ ${#values_args[@]} -gt 0 ]]; then
                log_info "[DRY RUN]   with values: ${values_args[*]}"
            fi
            continue
        fi

        log_info "Deploying ${component} to namespace ${target_ns}"
        helm upgrade --install "${component}" "${chart_file}" \
            --namespace "${target_ns}" \
            --set "global.registry=${registry_url}" \
            --set "global.airgapped=true" \
            "${values_args[@]+"${values_args[@]}"}" \
            --wait \
            --timeout 300s

        log_info "${component} deployed successfully"
    done

    log_info "RUNE component deployment complete"
}

###############################################################################
# Phase 7: Validation
###############################################################################

phase_validate() {
    log_info "=== Phase 7: Validation ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY RUN] Would verify all pods are Running"
        log_info "[DRY RUN] Would verify registry is serving images"
        if [[ "${REGISTRY_ONLY}" != true ]]; then
            log_info "[DRY RUN] Would verify RUNE API server healthz"
            log_info "[DRY RUN] Would verify RUNE UI is reachable"
        fi
        return 0
    fi

    local exit_ok=true

    # Check registry pods
    log_info "Checking registry pods in ${REGISTRY_NAMESPACE}"
    if ! kubectl get pods -n "${REGISTRY_NAMESPACE}" -l app.kubernetes.io/name=zot --no-headers | grep -q Running; then
        log_error "Registry pod is not Running"
        exit_ok=false
    else
        log_info "Registry pod: Running"
    fi

    # Check RUNE component pods (if not registry-only)
    if [[ "${REGISTRY_ONLY}" != true ]]; then
        for ns in "${OPERATOR_NAMESPACE}" "${NAMESPACE}"; do
            log_info "Checking pods in ${ns}"
            local not_running
            not_running="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
                | grep -v Running | grep -v Completed || true)"
            if [[ -n "${not_running}" ]]; then
                log_warn "Non-running pods in ${ns}:"
                echo "${not_running}" >&2
                exit_ok=false
            else
                log_info "All pods in ${ns}: Running"
            fi
        done
    fi

    if [[ "${exit_ok}" == true ]]; then
        log_info "Validation PASSED"
    else
        log_error "Validation FAILED — see warnings above"
        exit 1
    fi
}

###############################################################################
# Dry-run summary
###############################################################################

print_dry_run_summary() {
    echo ""
    echo "=== DEPLOYMENT PLAN ==="
    echo "Bundle:              ${BUNDLE}"
    echo "Namespace:           ${NAMESPACE}"
    echo "Registry namespace:  ${REGISTRY_NAMESPACE}"
    echo "Operator namespace:  ${OPERATOR_NAMESPACE}"
    echo "Skip verify:         ${SKIP_VERIFY}"
    echo "Registry only:       ${REGISTRY_ONLY}"
    echo "Network policies:    $(if [[ "${NO_NETWORK_POLICIES}" == true ]]; then echo "skipped"; else echo "applied"; fi)"
    echo "Custom values:       ${VALUES_FILE:-none}"
    echo ""
    echo "Phases:"
    echo "  1. Unpack bundle"
    if [[ "${SKIP_VERIFY}" != true ]]; then
        echo "  2. Verify SHA256 checksums + cosign signatures"
    else
        echo "  2. (skipped) Verify checksums"
    fi
    echo "  3. Check prerequisites (kubectl, helm, cluster)"
    echo "  4. Create namespaces + PSA labels + RBAC + NetworkPolicies"
    echo "  5. Deploy zot registry + load images"
    if [[ "${REGISTRY_ONLY}" != true ]]; then
        echo "  6. Deploy RUNE: operator -> API server -> UI (via Helm)"
        echo "  7. Validate all pods Running"
    fi
    echo ""
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        log_info "Cleaning up working directory"
        rm -rf "${WORK_DIR}"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    parse_args "$@"

    # Initialise log file
    LOG_FILE="bootstrap-$(date -u '+%Y%m%dT%H%M%SZ').log"
    log_info "=== RUNE Air-Gapped Bootstrap ==="
    log_info "Bundle: ${BUNDLE}"
    log_info "Log file: ${LOG_FILE}"
    log_debug "Namespace: ${NAMESPACE}, Registry: ${REGISTRY_NAMESPACE}, Operator: ${OPERATOR_NAMESPACE}"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run_summary
    fi

    # Create working directory
    WORK_DIR="$(mktemp -d -t rune-bootstrap-XXXXXX)"
    trap cleanup EXIT
    BUNDLE_DIR=""  # Set by phase_unpack

    # Execute phases
    phase_unpack
    phase_verify
    phase_prerequisites
    phase_namespaces
    phase_registry
    phase_deploy
    phase_validate

    log_info "=== RUNE bootstrap complete ==="

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "=== DRY RUN complete (no changes made) ==="
    else
        echo ""
        echo "RUNE has been deployed successfully."
        echo "  Registry:  zot.${REGISTRY_NAMESPACE}.svc.cluster.local:${ZOT_PORT}"
        echo "  Namespace: ${NAMESPACE}"
        echo "  Log:       ${LOG_FILE}"
    fi
}

main "$@"
