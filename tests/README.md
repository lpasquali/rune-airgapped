# RUNE — Airgapped Test Suite

This directory contains shell-based integration and unit tests for airgapped deployment scripts.

## Directory Structure

- **`bundle/`**: Tests for OCI bundle generation, integrity checking, and TLS certificate generation.
- **`lifecycle/`**: Tests for the full installation lifecycle: bootstrap, configuration, health checks, upgrades, and rollbacks.

## Running Tests

Tests are standalone bash scripts:

```bash
# Run all bundle tests
for f in tests/bundle/*.sh; do bash "$f" || exit $?; done

# Run all lifecycle tests
for f in tests/lifecycle/*.sh; do bash "$f" || exit $?; done
```
