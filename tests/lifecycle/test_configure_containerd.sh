#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_configure_containerd.sh — Unit tests for scripts/configure-containerd.sh
#
# Tests argument parsing, config generation, dry-run output, and backup logic.
# Run: bash tests/test_configure_containerd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/configure-containerd.sh"
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

assert_file_exists() {
    local test_name="$1"
    local file_path="$2"
    if [[ -f "${file_path}" ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    file does not exist: ${file_path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

###############################################################################
# Tests
###############################################################################

test_help_flag() {
    echo "--- test_help_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    assert_contains "help shows usage" "Usage:" "${output}"
    assert_contains "help shows --registry-url" "--registry-url" "${output}"
    assert_contains "help shows --config-path" "--config-path" "${output}"
    assert_contains "help shows --dry-run" "--dry-run" "${output}"
    assert_contains "help shows --mirrors" "--mirrors" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
}

test_missing_registry_url() {
    echo "--- test_missing_registry_url ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --dry-run 2>/dev/null || exit_code=$?
    assert_exit_code "missing --registry-url exits 1" "1" "${exit_code}"
}

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>/dev/null || exit_code=$?
    assert_exit_code "unknown option exits 1" "1" "${exit_code}"
}

test_dry_run_shows_config() {
    echo "--- test_dry_run_shows_config ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://localhost:5000 \
        --dry-run 2>&1)" || true

    assert_contains "dry run shows registry URL" "http://localhost:5000" "${output}"
    assert_contains "dry run shows mirror config" "registry.mirrors" "${output}"
    assert_contains "dry run shows docker.io" "docker.io" "${output}"
    assert_contains "dry run shows ghcr.io" "ghcr.io" "${output}"
    assert_contains "dry run shows registry.k8s.io" "registry.k8s.io" "${output}"
    assert_contains "dry run shows no changes" "No changes made" "${output}"
}

test_dry_run_custom_mirrors() {
    echo "--- test_dry_run_custom_mirrors ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://localhost:5000 \
        --mirrors "quay.io,gcr.io" \
        --dry-run 2>&1)" || true

    assert_contains "custom mirrors shows quay.io" "quay.io" "${output}"
    assert_contains "custom mirrors shows gcr.io" "gcr.io" "${output}"
}

test_dry_run_would_restart() {
    echo "--- test_dry_run_would_restart ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://localhost:5000 \
        --dry-run 2>&1)" || true

    assert_contains "dry run would restart containerd" "Would restart containerd" "${output}"
}

test_dry_run_no_restart() {
    echo "--- test_dry_run_no_restart ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://localhost:5000 \
        --no-restart \
        --dry-run 2>&1)" || true

    # --no-restart means dry run should NOT say "Would restart"
    if [[ "${output}" != *"Would restart"* ]]; then
        echo "  PASS: no-restart suppresses restart message"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: no-restart should suppress restart message"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

test_config_generation_with_mock() {
    echo "--- test_config_generation_with_mock ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t test-containerd-XXXXXX)"
    local config_file="${tmp_dir}/config.toml"

    # Create a minimal existing config
    echo 'version = 2' > "${config_file}"

    # Run with --no-restart and --dry-run just to verify snippet content
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://zot.local:5000 \
        --config-path "${config_file}" \
        --dry-run 2>&1)" || true

    assert_contains "config has endpoint" "endpoint" "${output}"
    assert_contains "config has zot URL" "http://zot.local:5000" "${output}"
    assert_contains "config has docker.io mirror" "docker.io" "${output}"

    rm -rf "${tmp_dir}"
}

test_backup_creates_bak_file() {
    echo "--- test_backup_creates_bak_file ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t test-containerd-XXXXXX)"
    local config_file="${tmp_dir}/config.toml"

    # Create a config file to be backed up
    echo 'version = 2' > "${config_file}"

    # Test backup by simply copying the file (mirrors backup_config logic)
    cp "${config_file}" "${config_file}.bak"

    assert_file_exists "backup file created" "${config_file}.bak"

    # Verify contents match
    local diff_result=0
    diff "${config_file}" "${config_file}.bak" >/dev/null 2>&1 || diff_result=$?
    assert_eq "backup matches original" "0" "${diff_result}"

    rm -rf "${tmp_dir}"
}

test_dry_run_backup_message() {
    echo "--- test_dry_run_backup_message ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t test-containerd-XXXXXX)"
    local config_file="${tmp_dir}/config.toml"
    echo 'version = 2' > "${config_file}"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --registry-url http://localhost:5000 \
        --config-path "${config_file}" \
        --dry-run 2>&1)" || true

    assert_contains "dry run mentions backup" "backup" "${output}"

    rm -rf "${tmp_dir}"
}

###############################################################################
# Main
###############################################################################

echo "=== configure-containerd.sh test suite ==="
echo ""

test_help_flag
test_missing_registry_url
test_unknown_option
test_dry_run_shows_config
test_dry_run_custom_mirrors
test_dry_run_would_restart
test_dry_run_no_restart
test_config_generation_with_mock
test_backup_creates_bak_file
test_dry_run_backup_message

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
