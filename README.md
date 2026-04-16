# RUNE (Reliability Use-case Numeric Evaluator) — Airgapped

Airgapped deployment bundler for the RUNE platform.

The default OCI bundle contains **RUNE suite images only** (rune, rune-operator, rune-ui, and supporting infrastructure). For **production**, provision PostgreSQL externally (CNPG, managed database) and configure via `RUNE_DB_URL` Secret. See [docs/deployment-guide.md](docs/deployment-guide.md) and [prerequisites matrix](docs/prerequisites.md).

For **development/lab** environments that need in-cluster PostgreSQL, build the bundle with `--include-postgres` flag. See [docs/deployment-guide.md#postgresql-optional](docs/deployment-guide.md#9-postgresql-optional) for details.

## 📖 Documentation
All documentation is consolidated in the **[RUNE Documentation Site](https://lpasquali.github.io/rune-docs/)**.

## 🛡️ Compliance
- **ML4**: This repository is designed to align with **IEC 62443-4-1 ML4** secure development requirements in preparation for future certification.
- **SLSA**: Build provenance is designed to follow **SLSA Level 3** guidelines.

## 📜 License
Apache License 2.0. See [LICENSE](LICENSE).
