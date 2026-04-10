#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_build_bundle.sh — Unit tests for scripts/build-bundle.sh
#
# Tests script functions by sourcing with mocked external commands.
# Run: bash tests/test_build_bundle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/build-bundle.sh"
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

###############################################################################
# Tests
###############################################################################

test_help_flag() {
    echo "--- test_help_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    assert_contains "help shows usage" "Usage:" "${output}"
    assert_contains "help shows --tag" "--tag" "${output}"
    assert_contains "help shows --output" "--output" "${output}"
    assert_contains "help shows --dry-run" "--dry-run" "${output}"
}

test_missing_tag() {
    echo "--- test_missing_tag ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --output /tmp/test.tar.gz 2>/dev/null || exit_code=$?
    assert_exit_code "missing --tag exits nonzero" "1" "${exit_code}"
}

test_missing_output() {
    echo "--- test_missing_output ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --tag v0.0.0a2 2>/dev/null || exit_code=$?
    assert_exit_code "missing --output exits nonzero" "1" "${exit_code}"
}

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>/dev/null || exit_code=$?
    assert_exit_code "unknown option exits nonzero" "1" "${exit_code}"
}

test_dry_run_mode() {
    echo "--- test_dry_run_mode ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --tag v0.0.0a2 \
        --output /tmp/test-bundle.tar.gz \
        --dry-run 2>&1)" || true

    assert_contains "dry run lists tag" "v0.0.0a2" "${output}"
    assert_contains "dry run lists images" "Container Images" "${output}"
    assert_contains "dry run lists helm charts" "Helm Charts" "${output}"
    assert_contains "dry run lists compliance" "Compliance Artifacts" "${output}"
    assert_contains "dry run lists integrity" "SHA256SUMS" "${output}"
    assert_contains "dry run shows rune image" "ghcr.io/lpasquali/rune" "${output}"
    assert_contains "dry run shows operator image" "ghcr.io/lpasquali/rune-operator" "${output}"
    assert_contains "dry run shows zot image" "zot-linux-amd64" "${output}"
    assert_contains "dry run shows postgres image" "library/postgres:17-alpine" "${output}"
}

test_dry_run_with_ollama() {
    echo "--- test_dry_run_with_ollama ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --tag v0.0.0a2 \
        --output /tmp/test-bundle.tar.gz \
        --include-ollama \
        --dry-run 2>&1)" || true

    assert_contains "dry run with ollama shows ollama image" "ollama/ollama" "${output}"
}

test_dry_run_with_sign() {
    echo "--- test_dry_run_with_sign ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --tag v0.0.0a2 \
        --output /tmp/test-bundle.tar.gz \
        --sign \
        --dry-run 2>&1)" || true

    # In dry-run mode, signing info should appear even without a key
    # (dry-run skips prerequisites check)
    assert_contains "dry run with sign shows signing" "Signing" "${output}"
}

test_dry_run_architectures() {
    echo "--- test_dry_run_architectures ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --tag v0.0.0a2 \
        --output /tmp/test-bundle.tar.gz \
        --arch amd64 \
        --dry-run 2>&1)" || true

    assert_contains "dry run shows custom arch" "amd64" "${output}"
}

test_dry_run_no_changes() {
    echo "--- test_dry_run_no_changes ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --tag v0.0.0a2 \
        --output /tmp/test-bundle.tar.gz \
        --dry-run 2>&1)" || true

    assert_contains "dry run says no changes" "no changes made" "${output}"
}

###############################################################################
# Main
###############################################################################

echo "=== build-bundle.sh test suite ==="
echo ""

test_help_flag
test_missing_tag
test_missing_output
test_unknown_option
test_dry_run_mode
test_dry_run_with_ollama
test_dry_run_with_sign
test_dry_run_architectures
test_dry_run_no_changes

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
