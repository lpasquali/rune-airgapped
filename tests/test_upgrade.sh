#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_upgrade.sh — Unit tests for scripts/upgrade.sh
#
# Tests script argument parsing, dry-run output, and error handling.
# Run: bash tests/test_upgrade.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/upgrade.sh"
readonly SCRIPT_UNDER_TEST

PASS_COUNT=0
FAIL_COUNT=0

###############################################################################
# Test helpers (same pattern as test_bootstrap.sh)
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
    local bundle_dir="${tmp_dir}/rune-bundle-v0.0.0a3"
    mkdir -p "${bundle_dir}/images/rune"
    mkdir -p "${bundle_dir}/charts"
    mkdir -p "${bundle_dir}/compliance/sboms"

    # Create a dummy manifest
    echo '{"version":"v0.0.0a3"}' > "${bundle_dir}/manifest.json"

    # Create SHA256SUMS
    (cd "${bundle_dir}" && find . -type f ! -name 'SHA256SUMS' -print0 \
        | sort -z | xargs -0 sha256sum | sed 's|  \./|  |') > "${bundle_dir}/SHA256SUMS"

    # Package tarball
    local tarball="${tmp_dir}/rune-bundle-v0.0.0a3.tar.gz"
    tar --sort=name -czf "${tarball}" \
        -C "${tmp_dir}" "rune-bundle-v0.0.0a3"

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
    assert_contains "help shows --skip-backup" "--skip-backup" "${output}"
    assert_contains "help shows --component" "--component" "${output}"
    assert_contains "help shows --values" "--values" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
    assert_contains "help shows rollback exit code" "3" "${output}"
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

test_invalid_component() {
    echo "--- test_invalid_component ---"
    local tarball
    tarball="$(create_test_bundle)"

    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --component invalid-component 2>/dev/null || exit_code=$?
    assert_exit_code "invalid component exits nonzero" "1" "${exit_code}"

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

test_dry_run_with_bundle() {
    echo "--- test_dry_run_with_bundle ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --dry-run 2>&1)" || true

    assert_contains "dry run shows upgrade plan" "UPGRADE PLAN" "${output}"
    assert_contains "dry run shows bundle path" "${tarball}" "${output}"
    assert_contains "dry run shows validate phase" "Validate bundle" "${output}"
    assert_contains "dry run shows backup phase" "Backup" "${output}"
    assert_contains "dry run shows load images phase" "Load new images" "${output}"
    assert_contains "dry run shows helm upgrade phase" "Helm upgrade" "${output}"
    assert_contains "dry run shows health check phase" "health checks" "${output}"
    assert_contains "dry run says no changes" "no changes made" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_skip_backup() {
    echo "--- test_dry_run_skip_backup ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --skip-backup \
        --dry-run 2>&1)" || true

    assert_contains "skip backup shows skipped" "skipped" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_single_component() {
    echo "--- test_dry_run_single_component ---"
    local tarball
    tarball="$(create_test_bundle)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --component rune-operator \
        --dry-run 2>&1)" || true

    assert_contains "single component shown" "rune-operator" "${output}"
    assert_contains "component filter noted" "rune-operator" "${output}"
    # Should NOT list rune-ui when filtering to rune-operator
    assert_not_contains "other components excluded" "rune-ui" "${output}"

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
        --operator-namespace custom-system \
        --dry-run 2>&1)" || true

    assert_contains "custom namespace shown" "custom-rune" "${output}"
    assert_contains "custom registry namespace shown" "custom-registry" "${output}"
    assert_contains "custom operator namespace shown" "custom-system" "${output}"

    rm -rf "$(dirname "${tarball}")"
}

test_dry_run_with_values() {
    echo "--- test_dry_run_with_values ---"
    local tarball
    tarball="$(create_test_bundle)"

    # Create a temp values file
    local values_file
    values_file="$(mktemp -t values-XXXXXX.yaml)"
    echo "key: value" > "${values_file}"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --bundle "${tarball}" \
        --values "${values_file}" \
        --dry-run 2>&1)" || true

    assert_contains "values file shown" "${values_file}" "${output}"

    rm -rf "$(dirname "${tarball}")" "${values_file}"
}

test_checksum_verification_in_bundle() {
    echo "--- test_checksum_verification_in_bundle ---"
    local tarball
    tarball="$(create_test_bundle)"

    # Unpack and verify checksums manually
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

###############################################################################
# Main
###############################################################################

echo "=== upgrade.sh test suite ==="
echo ""

test_help_flag
test_missing_bundle
test_bundle_not_found
test_unknown_option
test_invalid_component
test_values_file_not_found
test_dry_run_with_bundle
test_dry_run_skip_backup
test_dry_run_single_component
test_dry_run_custom_namespaces
test_dry_run_with_values
test_checksum_verification_in_bundle

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
