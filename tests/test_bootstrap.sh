#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_bootstrap.sh — Unit tests for scripts/bootstrap.sh
#
# Tests script argument parsing, dry-run output, and error handling.
# Run: bash tests/test_bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/bootstrap.sh"
readonly SCRIPT_UNDER_TEST

PASS_COUNT=0
FAIL_COUNT=0

###############################################################################
# Test helpers
###############################################################################

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    expected: ${expected}"
        echo "    actual:   ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    expected to contain: ${needle}"
        echo "    actual: ${haystack}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_not_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    expected NOT to contain: ${needle}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_exit_code() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    expected exit code: ${expected}"
        echo "    actual exit code:   ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

###############################################################################
# Fixture: create a minimal test bundle
###############################################################################

create_test_bundle() {
    local tmp_dir
    tmp_dir="$(mktemp -d -t test-bundle-XXXXXX)"
    local bundle_dir="${tmp_dir}/rune-bundle-v0.0.0a2"
    mkdir -p "${bundle_dir}/images/rune"
    mkdir -p "${bundle_dir}/images/zot-linux-amd64"
    mkdir -p "${bundle_dir}/charts"
    mkdir -p "${bundle_dir}/compliance/sboms"
    mkdir -p "${bundle_dir}/compliance/vex"
    mkdir -p "${bundle_dir}/manifests"

    # Create a dummy manifest
    echo '{"version":"v0.0.0a2"}' > "${bundle_dir}/manifest.json"

    # Create SHA256SUMS
    (cd "${bundle_dir}" && find . -type f ! -name 'SHA256SUMS' -print0 \
        | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "${bundle_dir}/SHA256SUMS"

    # Package tarball
    local tarball="${tmp_dir}/rune-bundle-v0.0.0a2.tar.gz"
    tar --sort=name -czf "${tarball}" \
        -C "${tmp_dir}" "rune-bundle-v0.0.0a2"

    echo "${tarball}"
}

###############################################################################
# Tests
###############################################################################

test_help_flag() {
    echo "--- test_help_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    assert_contains "help shows usage" "Usage:" "${output}"
    assert_contains "help shows --bundle" "--bundle" "${output}"
    assert_contains "help shows --dry-run" "--dry-run" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
}

test_missing_bundle() {
    echo "--- test_missing_bundle ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" 2>/dev/null || exit_code=$?
    assert_exit_code "missing --bundle exits nonzero" "1" "${exit_code}"
}

test_bundle_not_found() {
    echo "--- test_bundle_not_found ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bundle /nonexistent/bundle.tar.gz 2>/dev/null || exit_code=$?
    assert_exit_code "nonexistent bundle exits nonzero" "1" "${exit_code}"
}

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>/dev/null || exit_code=$?
    assert_exit_code "unknown option exits nonzero" "1" "${exit_code}"
}

test_dry_run_with_bundle() {
    echo "--- test_dry_run_with_bundle ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --dry-run 2>&1)" || true

    assert_contains "dry run shows deployment plan" "DEPLOYMENT PLAN" "${output}"
    assert_contains "dry run shows bundle path" "${tarball}" "${output}"
    assert_contains "dry run shows unpack phase" "Unpack" "${output}"
    assert_contains "dry run shows verify phase" "Verify" "${output}"
    assert_contains "dry run shows prerequisites phase" "prerequisites" "${output}"
    assert_contains "dry run shows namespaces phase" "namespaces" "${output}"
    assert_contains "dry run shows registry phase" "registry" "${output}"
    assert_contains "dry run shows deploy phase" "Deploy RUNE" "${output}"
    assert_contains "dry run says no changes" "no changes made" "${output}"

    # Clean up
    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_skip_verify() {
    echo "--- test_dry_run_skip_verify ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --skip-verify \
        --dry-run 2>&1)" || true

    assert_contains "skip verify shows skipped" "skipped" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_registry_only() {
    echo "--- test_dry_run_registry_only ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --registry-only \
        --dry-run 2>&1)" || true

    assert_contains "registry-only noted" "registry-only" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_custom_namespaces() {
    echo "--- test_dry_run_custom_namespaces ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --namespace custom-rune \
        --registry-namespace custom-registry \
        --dry-run 2>&1)" || true

    assert_contains "custom namespace shown" "custom-rune" "${output}"
    assert_contains "custom registry namespace shown" "custom-registry" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_no_network_policies() {
    echo "--- test_dry_run_no_network_policies ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --no-network-policies \
        --dry-run 2>&1)" || true

    assert_contains "network policies skipped" "skipped" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_values_file_not_found() {
    echo "--- test_values_file_not_found ---"
    local tarball
    tarball="$(create_test_bundle)"

    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --values /nonexistent/values.yaml 2>/dev/null || exit_code=$?

    assert_exit_code "nonexistent values file exits nonzero" "1" "${exit_code}"

    rm -rf "$(dirname "${tarball}")"
}

test_checksum_verification_pass() {
    echo "--- test_checksum_verification_pass ---"
    local tarball
    tarball="$(create_test_bundle)"

    # Unpack and verify checksums manually (mimics phase_verify)
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    tar xzf "${tarball}" -C "${tmp_dir}"
    local bundle_dir
    bundle_dir="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    local exit_code=0
    (cd "${bundle_dir}" && sha256sum -c SHA256SUMS --quiet 2>&1) || exit_code=$?
    assert_exit_code "valid checksums pass" "0" "${exit_code}"

    rm -rf "${tmp_dir}" "$(dirname "${tarball}")"
}

test_checksum_verification_fail() {
    echo "--- test_checksum_verification_fail ---"
    local tarball
    tarball="$(create_test_bundle)"

    # Unpack, corrupt a file, verify checksums fail
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    tar xzf "${tarball}" -C "${tmp_dir}"
    local bundle_dir
    bundle_dir="$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    # Corrupt manifest.json
    echo "corrupted" > "${bundle_dir}/manifest.json"

    local exit_code=0
    (cd "${bundle_dir}" && sha256sum -c SHA256SUMS --quiet 2>/dev/null) || exit_code=$?
    assert_exit_code "corrupted file fails checksum" "1" "${exit_code}"

    rm -rf "${tmp_dir}" "$(dirname "${tarball}")"
}

###############################################################################
# Main
###############################################################################

echo "=== bootstrap.sh test suite ==="
echo ""

test_help_flag
test_missing_bundle
test_bundle_not_found
test_unknown_option
test_dry_run_with_bundle
test_dry_run_skip_verify
test_dry_run_registry_only
test_dry_run_custom_namespaces
test_dry_run_no_network_policies
test_values_file_not_found
test_checksum_verification_pass
test_checksum_verification_fail

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
