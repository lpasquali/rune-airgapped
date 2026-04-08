#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_rollback.sh — Unit tests for scripts/rollback.sh
#
# Tests script argument parsing, dry-run output, and error handling.
# Run: bash tests/test_rollback.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/rollback.sh"
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
# Tests
###############################################################################

test_help_flag() {
    echo "--- test_help_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    assert_contains "help shows usage" "Usage:" "${output}"
    assert_contains "help shows --namespace" "--namespace" "${output}"
    assert_contains "help shows --component" "--component" "${output}"
    assert_contains "help shows --revision" "--revision" "${output}"
    assert_contains "help shows --dry-run" "--dry-run" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
}

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>/dev/null || exit_code=$?
    assert_exit_code "unknown option exits nonzero" "1" "${exit_code}"
}

test_invalid_component() {
    echo "--- test_invalid_component ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --component invalid-component 2>/dev/null || exit_code=$?
    assert_exit_code "invalid component exits nonzero" "1" "${exit_code}"
}

test_invalid_revision() {
    echo "--- test_invalid_revision ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --revision abc 2>/dev/null || exit_code=$?
    assert_exit_code "non-numeric revision exits nonzero" "1" "${exit_code}"
}

test_dry_run_default() {
    echo "--- test_dry_run_default ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --dry-run 2>&1)" || true

    assert_contains "dry run shows rollback plan" "ROLLBACK PLAN" "${output}"
    assert_contains "dry run shows default namespace" "rune" "${output}"
    assert_contains "dry run shows revision info phase" "revision info" "${output}"
    assert_contains "dry run shows helm rollback phase" "Helm rollback" "${output}"
    assert_contains "dry run shows wait pods phase" "pods to stabilise" "${output}"
    assert_contains "dry run shows health check phase" "health checks" "${output}"
    assert_contains "dry run says no changes" "no changes made" "${output}"
}

test_dry_run_single_component() {
    echo "--- test_dry_run_single_component ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --component rune-ui \
        --dry-run 2>&1)" || true

    assert_contains "single component shown" "rune-ui" "${output}"
    # Should NOT list rune-operator when filtering to rune-ui
    assert_not_contains "other components excluded" "rune-operator" "${output}"
}

test_dry_run_with_revision() {
    echo "--- test_dry_run_with_revision ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --revision 3 \
        --dry-run 2>&1)" || true

    assert_contains "target revision shown" "3" "${output}"
}

test_dry_run_custom_namespaces() {
    echo "--- test_dry_run_custom_namespaces ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --namespace custom-rune \
        --operator-namespace custom-system \
        --dry-run 2>&1)" || true

    assert_contains "custom namespace shown" "custom-rune" "${output}"
    assert_contains "custom operator namespace shown" "custom-system" "${output}"
}

test_dry_run_all_components_listed() {
    echo "--- test_dry_run_all_components_listed ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --dry-run 2>&1)" || true

    assert_contains "rune-ui in list" "rune-ui" "${output}"
    assert_contains "rune in list" "rune" "${output}"
    assert_contains "rune-operator in list" "rune-operator" "${output}"
}

test_dry_run_verbose() {
    echo "--- test_dry_run_verbose ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --dry-run --verbose 2>&1)" || true

    assert_contains "verbose dry run completes" "DRY RUN complete" "${output}"
}

###############################################################################
# Main
###############################################################################

echo "=== rollback.sh test suite ==="
echo ""

test_help_flag
test_unknown_option
test_invalid_component
test_invalid_revision
test_dry_run_default
test_dry_run_single_component
test_dry_run_with_revision
test_dry_run_custom_namespaces
test_dry_run_all_components_listed
test_dry_run_verbose

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
