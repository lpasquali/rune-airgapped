#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 RUNE Contributors
#
# test_generate_tls.sh — Unit tests for scripts/generate-tls.sh
#
# Tests certificate generation, argument parsing, dry-run behaviour,
# and SAN validation.
# Run: bash tests/test_generate_tls.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
SCRIPT_UNDER_TEST="${REPO_ROOT}/scripts/generate-tls.sh"
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

assert_file_exists() {
    local test_name="$1"
    local file_path="$2"
    if [[ -f "${file_path}" ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    file not found: ${file_path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_not_exists() {
    local test_name="$1"
    local file_path="$2"
    if [[ ! -f "${file_path}" ]]; then
        echo "  PASS: ${test_name}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${test_name}"
        echo "    file should not exist: ${file_path}"
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
    assert_contains "help shows --output-dir" "--output-dir" "${output}"
    assert_contains "help shows --ca-cert" "--ca-cert" "${output}"
    assert_contains "help shows --ca-key" "--ca-key" "${output}"
    assert_contains "help shows --days" "--days" "${output}"
    assert_contains "help shows --san" "--san" "${output}"
    assert_contains "help shows --apply" "--apply" "${output}"
    assert_contains "help shows --dry-run" "--dry-run" "${output}"
    assert_contains "help shows --verbose" "--verbose" "${output}"
    assert_contains "help shows exit codes" "Exit codes" "${output}"
    assert_contains "help shows services" "rune-api" "${output}"
}

test_unknown_option() {
    echo "--- test_unknown_option ---"
    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --bad-flag 2>/dev/null || exit_code=$?
    assert_exit_code "unknown option exits 1" "1" "${exit_code}"
}

test_ca_cert_without_key() {
    echo "--- test_ca_cert_without_key ---"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # Create a dummy CA cert file
    touch "${tmp_dir}/ca.crt"

    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --ca-cert "${tmp_dir}/ca.crt" 2>/dev/null || exit_code=$?
    assert_exit_code "ca-cert without ca-key exits 1" "1" "${exit_code}"

    rm -rf "${tmp_dir}"
}

test_ca_key_without_cert() {
    echo "--- test_ca_key_without_cert ---"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    touch "${tmp_dir}/ca.key"

    local exit_code=0
    bash "${SCRIPT_UNDER_TEST}" --ca-key "${tmp_dir}/ca.key" 2>/dev/null || exit_code=$?
    assert_exit_code "ca-key without ca-cert exits 1" "1" "${exit_code}"

    rm -rf "${tmp_dir}"
}

test_missing_openssl() {
    echo "--- test_missing_openssl ---"
    # Create a temp directory with only bash (no openssl) to simulate missing openssl
    local fake_bin
    fake_bin="$(mktemp -d)"
    # Symlink only essential commands (bash, date, basename, dirname, printf, mkdir)
    for cmd in bash date basename dirname printf mkdir; do
        local cmd_path
        cmd_path="$(command -v "${cmd}" 2>/dev/null)" || true
        if [[ -n "${cmd_path}" ]]; then
            ln -sf "${cmd_path}" "${fake_bin}/${cmd}"
        fi
    done
    # Add coreutils that bash builtins need
    for cmd in env cat; do
        local cmd_path
        cmd_path="$(command -v "${cmd}" 2>/dev/null)" || true
        if [[ -n "${cmd_path}" ]]; then
            ln -sf "${cmd_path}" "${fake_bin}/${cmd}"
        fi
    done

    local exit_code=0
    env PATH="${fake_bin}" bash "${SCRIPT_UNDER_TEST}" --output-dir /tmp/tls-test 2>/dev/null || exit_code=$?
    assert_exit_code "missing openssl exits 2" "2" "${exit_code}"

    rm -rf "${fake_bin}"
}

test_self_signed_generation() {
    echo "--- test_self_signed_generation ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    local exit_code=0
    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" \
        --namespace test-ns \
        --days 30 2>&1)" || exit_code=$?

    assert_exit_code "self-signed generation succeeds" "0" "${exit_code}"

    # Check CA files
    assert_file_exists "CA key exists" "${tmp_dir}/tls/ca.key"
    assert_file_exists "CA cert exists" "${tmp_dir}/tls/ca.crt"

    # Check service cert files
    for svc in rune-api rune-ui rune-registry; do
        assert_file_exists "${svc} server.key exists" "${tmp_dir}/tls/${svc}/server.key"
        assert_file_exists "${svc} server.crt exists" "${tmp_dir}/tls/${svc}/server.crt"
        # CSR should have been cleaned up
        assert_file_not_exists "${svc} CSR cleaned up" "${tmp_dir}/tls/${svc}/server.csr"
    done

    assert_contains "output mentions summary" "TLS Certificate Generation Summary" "${output}"
    assert_contains "output mentions self-signed mode" "self-signed" "${output}"

    rm -rf "${tmp_dir}"
}

test_cert_has_correct_sans() {
    echo "--- test_cert_has_correct_sans ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" \
        --namespace myns \
        --san extra.example.com 2>/dev/null || true

    for svc in rune-api rune-ui rune-registry; do
        local san_output
        san_output="$(openssl x509 -noout -text -in "${tmp_dir}/tls/${svc}/server.crt" 2>/dev/null \
            | grep -A1 "Subject Alternative Name" || true)"

        assert_contains "${svc} has cluster.local SAN" "${svc}.myns.svc.cluster.local" "${san_output}"
        assert_contains "${svc} has svc SAN" "${svc}.myns.svc" "${san_output}"
        assert_contains "${svc} has short SAN" "DNS:${svc}" "${san_output}"
        assert_contains "${svc} has extra SAN" "extra.example.com" "${san_output}"
    done

    rm -rf "${tmp_dir}"
}

test_cert_validates_against_ca() {
    echo "--- test_cert_validates_against_ca ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" 2>/dev/null || true

    for svc in rune-api rune-ui rune-registry; do
        local verify_exit=0
        openssl verify -CAfile "${tmp_dir}/tls/ca.crt" \
            "${tmp_dir}/tls/${svc}/server.crt" >/dev/null 2>&1 || verify_exit=$?
        assert_exit_code "${svc} cert verifies against CA" "0" "${verify_exit}"
    done

    rm -rf "${tmp_dir}"
}

test_customer_ca_mode() {
    echo "--- test_customer_ca_mode ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    # Generate a customer CA first
    openssl genrsa -out "${tmp_dir}/customer-ca.key" 2048 2>/dev/null
    openssl req -new -x509 \
        -key "${tmp_dir}/customer-ca.key" \
        -out "${tmp_dir}/customer-ca.crt" \
        -days 30 \
        -subj "/CN=Customer CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        2>/dev/null

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --ca-cert "${tmp_dir}/customer-ca.crt" \
        --ca-key "${tmp_dir}/customer-ca.key" \
        --output-dir "${tmp_dir}/tls" 2>&1)" || true

    assert_contains "output mentions customer CA" "customer-ca" "${output}"

    # CA should NOT have been regenerated in the output directory
    assert_file_not_exists "no generated CA key" "${tmp_dir}/tls/ca.key"

    # Certs should verify against the customer CA
    for svc in rune-api rune-ui rune-registry; do
        assert_file_exists "${svc} cert exists" "${tmp_dir}/tls/${svc}/server.crt"
        local verify_exit=0
        openssl verify -CAfile "${tmp_dir}/customer-ca.crt" \
            "${tmp_dir}/tls/${svc}/server.crt" >/dev/null 2>&1 || verify_exit=$?
        assert_exit_code "${svc} cert verifies against customer CA" "0" "${verify_exit}"
    done

    rm -rf "${tmp_dir}"
}

test_dry_run_no_files() {
    echo "--- test_dry_run_no_files ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" \
        --dry-run 2>&1)" || true

    assert_contains "dry run shows DRY RUN tag" "DRY RUN" "${output}"
    assert_contains "dry run shows no changes made" "no changes made" "${output}"

    # No files should have been created
    assert_file_not_exists "no CA key in dry run" "${tmp_dir}/tls/ca.key"
    assert_file_not_exists "no CA cert in dry run" "${tmp_dir}/tls/ca.crt"
    assert_file_not_exists "no rune-api cert in dry run" "${tmp_dir}/tls/rune-api/server.crt"

    rm -rf "${tmp_dir}"
}

test_dry_run_with_apply() {
    echo "--- test_dry_run_with_apply ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" \
        --apply \
        --dry-run 2>&1)" || true

    assert_contains "dry run mentions secrets" "Would create secret" "${output}"
    assert_contains "dry run mentions rune-api-tls" "rune-api-tls" "${output}"

    rm -rf "${tmp_dir}"
}

test_verbose_output() {
    echo "--- test_verbose_output ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    local output
    output="$(bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" \
        --verbose 2>&1)" || true

    assert_contains "verbose shows DEBUG" "DEBUG" "${output}"
    assert_contains "verbose shows SAN info" "SAN" "${output}"

    rm -rf "${tmp_dir}"
}

test_key_cert_modulus_match() {
    echo "--- test_key_cert_modulus_match ---"
    local tmp_dir
    tmp_dir="$(mktemp -d -t tls-test-XXXXXX)"

    bash "${SCRIPT_UNDER_TEST}" \
        --output-dir "${tmp_dir}/tls" 2>/dev/null || true

    for svc in rune-api rune-ui rune-registry; do
        local cert_mod key_mod
        cert_mod="$(openssl x509 -noout -modulus -in "${tmp_dir}/tls/${svc}/server.crt" 2>/dev/null)"
        key_mod="$(openssl rsa -noout -modulus -in "${tmp_dir}/tls/${svc}/server.key" 2>/dev/null)"
        assert_eq "${svc} key matches cert" "${cert_mod}" "${key_mod}"
    done

    rm -rf "${tmp_dir}"
}

###############################################################################
# Main
###############################################################################

echo "=== generate-tls.sh test suite ==="
echo ""

test_help_flag
test_unknown_option
test_ca_cert_without_key
test_ca_key_without_cert
test_missing_openssl
test_self_signed_generation
test_cert_has_correct_sans
test_cert_validates_against_ca
test_customer_ca_mode
test_dry_run_no_files
test_dry_run_with_apply
test_verbose_output
test_key_cert_modulus_match

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
fi
