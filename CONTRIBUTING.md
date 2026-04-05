# Contributing to rune-airgapped

Thank you for considering contributing to rune-airgapped!

## Where do I go from here?

If you've noticed a bug or have a feature request, open an issue. It's generally best to get confirmation of your bug or approval for your feature before starting to code.

## Development setup

```bash
git clone https://github.com/lpasquali/rune-airgapped
cd rune-airgapped

# Install shellcheck for script linting
sudo apt-get install shellcheck

# Validate scripts
shellcheck scripts/*.sh
```

## Code style

- **Shell scripts**: POSIX-compatible where possible, bash where necessary. Pass `shellcheck`.
- **YAML**: Validate with `yamllint`. Helm templates validated via `helm lint`.
- **Documentation**: Mermaid.js for diagrams, no binary images.

## Testing

All scripts must be testable in a non-destructive mode:
- `--dry-run` flag for any destructive operation
- Mock/stub external tools when running in CI

## Pull Request process

1. Fork and create a descriptive branch.
2. Ensure all CI gates pass (shellcheck, yamllint, secrets scan, license check).
3. Update documentation if behaviour changes.
4. Coverage: 97% floor for any Python tooling.

## Code of Conduct

Please note that this project is released with a Contributor Code of Conduct. By participating in this project you agree to abide by its terms.
