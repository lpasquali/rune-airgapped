#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_health_check.sh — Unit tests for scripts/health-check.sh
#
# Tests script argument parsing, usage output, error handling, and
# individual functions via source-and-call pattern.
# Run: bash tests/test_health_check.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/health-check.sh"
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
# Tests: Usage and help
###############################################################################

test_help_flag() {
    echo "--- test_help_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    assert_contains "help shows usage" "Usage:" "${output}"
    assert_contains "help shows --namespace" "--namespace" "${output}"
    assert_contains "help shows --registry-namespace" "--registry-namespace" "${output}"
    assert_contains "help shows --operator-namespace" "--operator-namespace" "${output}"
    assert_contains "help shows --verbose" "--verbose" "${output}"
    assert_contains "help shows --timeout" "--timeout" "${output}"
    assert_contains "help shows --skip-registry" "--skip-registry" "${output}"
    assert_contains "help shows --skip-api" "--skip-api" "${output}"
    assert_contains "help shows --skip-ui" "--skip-ui" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
}

test_help_short_flag() {
    echo "--- test_help_short_flag ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" -h 2>&1)" || true
    assert_contains "short help shows usage" "Usage:" "${output}"
}

###############################################################################
# Tests: Error handling
###############################################################################

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>&1)" || exit_code=$?
    assert_exit_code "unknown option exits nonzero" "1" "${exit_code}"
    assert_contains "unknown option shows error" "Unknown option" "${output}"
}

test_missing_kubectl() {
    echo "--- test_missing_kubectl ---"
    # Run with a PATH that has bash but not kubectl
    local bash_dir
    bash_dir="$(dirname "$(command -v bash)")"
    local exit_code=0
    local output
    output="$(PATH="${bash_dir}:/usr/bin:/bin" KUBECONFIG=/nonexistent/kubeconfig bash -c '
        # Hide kubectl
        kubectl() { return 127; }
        export -f kubectl 2>/dev/null || true
        # Re-exec the script with kubectl hidden
        exec env PATH=/usr/bin:/bin bash "'"${SCRIPT_UNDER_TEST}"'"
    ' 2>&1)" || exit_code=$?
    # If kubectl is present on the system, this test may hit "Cannot connect" instead.
    # Accept either exit code 2 outcome.
    if [[ "${exit_code}" -eq 2 ]]; then
        assert_exit_code "missing kubectl or no cluster exits 2" "2" "${exit_code}"
        # Check for either error message
        if [[ "${output}" == *"kubectl not found"* ]] || [[ "${output}" == *"Cannot connect"* ]]; then
            echo "  PASS: missing kubectl shows appropriate error"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "  FAIL: missing kubectl shows appropriate error"
            echo "    actual: ${output}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        assert_exit_code "missing kubectl exits 2" "2" "${exit_code}"
        assert_contains "missing kubectl shows error" "kubectl" "${output}"
    fi
}

###############################################################################
# Tests: Argument parsing via sourcing
###############################################################################

test_parse_args_defaults() {
    echo "--- test_parse_args_defaults ---"
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" --help 2>&1)" || true
    # The --help flag causes an early exit; verify it does not crash
    assert_contains "parse_args handles --help" "Usage:" "${output}"
}

test_parse_args_namespace() {
    echo "--- test_parse_args_namespace ---"
    # Use sed to strip the final 'main "$@"' line so we can source without executing main
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --namespace custom-ns
        echo "NS=${NAMESPACE}"
    ' 2>&1)" || true
    assert_contains "custom namespace parsed" "NS=custom-ns" "${output}"
}

test_parse_args_registry_namespace() {
    echo "--- test_parse_args_registry_namespace ---"
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --registry-namespace custom-reg
        echo "RNS=${REGISTRY_NAMESPACE}"
    ' 2>&1)" || true
    assert_contains "custom registry namespace parsed" "RNS=custom-reg" "${output}"
}

test_parse_args_operator_namespace() {
    echo "--- test_parse_args_operator_namespace ---"
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --operator-namespace custom-op
        echo "ONS=${OPERATOR_NAMESPACE}"
    ' 2>&1)" || true
    assert_contains "custom operator namespace parsed" "ONS=custom-op" "${output}"
}

test_parse_args_verbose() {
    echo "--- test_parse_args_verbose ---"
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --verbose
        echo "VERBOSE=${VERBOSE}"
    ' 2>&1)" || true
    assert_contains "verbose flag parsed" "VERBOSE=true" "${output}"
}

test_parse_args_timeout() {
    echo "--- test_parse_args_timeout ---"
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --timeout 60
        echo "TIMEOUT=${TIMEOUT}"
    ' 2>&1)" || true
    assert_contains "timeout value parsed" "TIMEOUT=60" "${output}"
}

test_parse_args_skip_flags() {
    echo "--- test_parse_args_skip_flags ---"
    local output
    output="$(bash -c '
        eval "$(sed "/^main \"\\\$@\"/d" "'"${SCRIPT_UNDER_TEST}"'")"
        parse_args --skip-registry --skip-api --skip-ui
        echo "SKIP_REGISTRY=${SKIP_REGISTRY}"
        echo "SKIP_API=${SKIP_API}"
        echo "SKIP_UI=${SKIP_UI}"
    ' 2>&1)" || true
    assert_contains "skip-registry parsed" "SKIP_REGISTRY=true" "${output}"
    assert_contains "skip-api parsed" "SKIP_API=true" "${output}"
    assert_contains "skip-ui parsed" "SKIP_UI=true" "${output}"
}

###############################################################################
# Tests: Logging functions
###############################################################################

test_log_info() {
    echo "--- test_log_info ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=false
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_info()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        log_info "test message"
    ' 2>&1)" || true
    assert_contains "log_info contains INFO" "INFO" "${output}"
    assert_contains "log_info contains message" "test message" "${output}"
}

test_log_debug_quiet() {
    echo "--- test_log_debug_quiet ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=false
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_debug()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        log_debug "hidden message"
    ' 2>&1)" || true
    assert_not_contains "log_debug silent without verbose" "hidden message" "${output}"
}

test_log_debug_verbose() {
    echo "--- test_log_debug_verbose ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=true
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_debug()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        log_debug "visible message"
    ' 2>&1)" || true
    assert_contains "log_debug visible with verbose" "visible message" "${output}"
}

###############################################################################
# Tests: Record helpers
###############################################################################

test_record_pass() {
    echo "--- test_record_pass ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=false
        CHECK_PASS=0
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_info()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^record_pass()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        record_pass "test-check"
        echo "COUNT=${CHECK_PASS}"
    ' 2>&1)" || true
    assert_contains "record_pass logs PASS" "PASS" "${output}"
    assert_contains "record_pass increments counter" "COUNT=1" "${output}"
}

test_record_fail() {
    echo "--- test_record_fail ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=false
        CHECK_FAIL=0
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_error()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^record_fail()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        record_fail "test-check" "some detail"
        echo "COUNT=${CHECK_FAIL}"
    ' 2>&1)" || true
    assert_contains "record_fail logs FAIL" "FAIL" "${output}"
    assert_contains "record_fail shows detail" "some detail" "${output}"
    assert_contains "record_fail increments counter" "COUNT=1" "${output}"
}

test_record_skip() {
    echo "--- test_record_skip ---"
    local output
    output="$(bash -c '
        LOG_FILE=""
        VERBOSE=false
        CHECK_SKIP=0
        source <(sed -n "/^log()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^log_info()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        source <(sed -n "/^record_skip()/,/^}/p" "'"${SCRIPT_UNDER_TEST}"'")
        record_skip "test-check"
        echo "COUNT=${CHECK_SKIP}"
    ' 2>&1)" || true
    assert_contains "record_skip logs SKIP" "SKIP" "${output}"
    assert_contains "record_skip increments counter" "COUNT=1" "${output}"
}

###############################################################################
# Tests: Exit code for no-cluster scenario
###############################################################################

test_no_cluster_exits_2() {
    echo "--- test_no_cluster_exits_2 ---"
    # Use a bogus kubeconfig to ensure kubectl cluster-info fails
    local exit_code=0
    local output
    output="$(KUBECONFIG=/nonexistent/kubeconfig bash "${SCRIPT_UNDER_TEST}" 2>&1)" || exit_code=$?
    assert_exit_code "no cluster exits 2" "2" "${exit_code}"
    assert_contains "no cluster shows error" "Cannot connect" "${output}"
}

###############################################################################
# Main
###############################################################################

echo "=== health-check.sh test suite ==="
echo ""

test_help_flag
test_help_short_flag
test_unknown_option
test_missing_kubectl
test_parse_args_defaults
test_parse_args_namespace
test_parse_args_registry_namespace
test_parse_args_operator_namespace
test_parse_args_verbose
test_parse_args_timeout
test_parse_args_skip_flags
test_log_info
test_log_debug_quiet
test_log_debug_verbose
test_record_pass
test_record_fail
test_record_skip
test_no_cluster_exits_2

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
