# RUNE (Reliability Use-case Numeric Evaluator) — Airgapped

Airgapped deployment bundler for the RUNE platform.

The OCI bundle includes **docker.io/library/postgres:17-alpine** so disconnected clusters can deploy RUNE with the optional in-chart PostgreSQL subchart (`postgres.enabled=true`). See [docs/deployment-guide.md](docs/deployment-guide.md#9-postgresql-air-gapped) and `values/postgres-airgapped.example.yaml`.

## 📖 Documentation
All documentation is consolidated in the **[RUNE Documentation Site](https://lpasquali.github.io/rune-docs/)**.

## 🛡️ Compliance
- **ML4**: This repository is designed to align with **IEC 62443-4-1 ML4** secure development requirements in preparation for future certification.
- **SLSA**: Build provenance is designed to follow **SLSA Level 3** guidelines.

## 📜 License
Apache License 2.0. See [LICENSE](LICENSE).
