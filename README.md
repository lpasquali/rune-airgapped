# RUNE (Reliability Use-case Numeric Evaluator) — Airgapped

Airgapped deployment bundler for the RUNE platform.

The default OCI bundle contains **RUNE suite images only** (rune, rune-operator, rune-ui, and supporting infrastructure). For **production**, provision [PostgreSQL](https://www.postgresql.org/docs/) externally ([CloudNativePG](https://cloudnative-pg.io/), managed database) and configure via `RUNE_DB_URL` Secret. See [docs/deployment-guide.md](docs/deployment-guide.md) and [prerequisites matrix](docs/prerequisites.md).

For **development/lab** environments that need in-cluster PostgreSQL, build the bundle with `--include-postgres` flag. See [docs/deployment-guide.md#postgresql-optional](docs/deployment-guide.md#9-postgresql-optional) for details.

## 📖 Documentation
All documentation is consolidated in the **[RUNE Documentation Site](https://lpasquali.github.io/rune-docs/)**.

## 🛡️ Compliance
- **ML4**: This repository is designed to align with **[IEC 62443-4-1](https://webstore.iec.ch/publication/33615) ML4** secure development requirements in preparation for future certification. ([ISA overview](https://www.isa.org/standards-and-publications/isa-standards/isa-iec-62443-series-of-standards))
- **SLSA**: Build provenance is designed to follow **[SLSA Level 3](https://slsa.dev/spec/v1.0/)** guidelines.

## 📜 License
Apache License 2.0. See [LICENSE](LICENSE).
