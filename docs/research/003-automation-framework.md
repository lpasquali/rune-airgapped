# ADR-003: Automation Framework

## Status

Accepted

## Context

The air-gapped deployment must be automated end-to-end: unpack the OCI bundle,
start the registry, verify artifact integrity, configure cluster nodes, and
deploy all RUNE components. The automation must be auditable (IEC 62443 SM-10),
idempotent, and work with minimal host dependencies.

The deployment has two distinct phases with different requirements:

1. **Pre-Kubernetes (bootstrap)**: Unpack bundle, start registry, generate TLS
   certs, configure containerd mirrors. No K8s API available yet (or cluster is
   bare). Requires only standard Linux tools.
2. **Kubernetes deployment (steady-state)**: Deploy Helm charts for all RUNE
   components in dependency order. K8s API is available. Requires Helm and
   declarative release management.

Key constraints:

- Minimal host dependencies on the target cluster.
- Idempotent (safe to re-run after failure or interruption).
- Auditable by a security reviewer with no specialized tooling knowledge.
- Must support dry-run mode for pre-deployment validation.
- Must handle ordering/dependencies between components.
- Portable across K8s distributions.

## Candidates Evaluated

| Tool | License | Phase Fit | Dependencies | Idempotent | Auditable | Verdict |
|------|---------|-----------|-------------- |------------|-----------|---------|
| **bash** | GPL-3.0 (system utility) | Pre-K8s bootstrap | None (ubiquitous) | Manual (with guards) | Yes (readable) | **Selected (bootstrap)** |
| **Helmfile** | MIT | K8s deployment | Helm, helm-diff plugin | Yes (declarative) | Yes (YAML) | **Selected (K8s deploy)** |
| Ansible | GPL-3.0 | Multi-node setup | Python 3 | Yes (modules) | Moderate | Deferred |
| Kustomize | Apache-2.0 | K8s manifests | kubectl | Partial | Yes (YAML) | Rejected |
| Fleet/Rancher GitOps | Apache-2.0 | Day 2 ops | Git server, Fleet agent | Yes | Low (complex) | Rejected |

### bash (bootstrap phase)

- **Pros**:
  - Zero dependencies beyond POSIX utilities. Available on every Linux system.
  - Fully auditable: a security reviewer can read every line and understand
    what it does without learning a DSL or framework.
  - Maximum portability across distributions.
  - Direct control over error handling (set -euo pipefail, trap handlers).
  - Perfect for sequential, imperative bootstrap steps.
- **Cons**:
  - Complex logic is harder to maintain than declarative approaches.
  - No built-in idempotency -- must be implemented via guard checks
    (e.g., `if ! kubectl get namespace rune-registry; then ...`).
  - No built-in parallelism or multi-node orchestration.
- **Role**: Pre-Kubernetes bootstrap only. All pre-K8s steps (unpack, verify,
  start registry, configure nodes) are sequential and imperative by nature,
  making bash the natural fit.

### Helmfile (K8s deployment phase)

- **Pros**:
  - Declarative Helm release management. Single `helmfile.yaml` defines all
    releases, their values, and dependency ordering.
  - Built-in `helmfile diff` for dry-run comparison before apply.
  - Supports environment-specific values overlays (dev, staging, production,
    air-gapped).
  - Idempotent by design: `helmfile apply` converges to desired state.
  - `helmfile sync` handles install-or-upgrade semantics.
  - MIT license, widely adopted in GitOps workflows.
- **Cons**:
  - Only handles Helm-based deployments -- cannot manage pre-K8s bootstrap,
    node configuration, or non-Helm resources.
  - Requires Helm CLI and helm-diff plugin (both single static binaries,
    included in bundle).
- **Role**: All Kubernetes-phase deployments. `helmfile.yaml` at repo root
  defines the complete RUNE deployment.

### Ansible (deferred)

- **Pros**:
  - Agentless (SSH-based), idempotent modules, excellent for multi-node
    cluster preparation (containerd mirror config, node labeling, kernel
    module loading).
  - Has kubernetes.core collection for K8s resource management.
  - Well-known in enterprise environments.
- **Cons**:
  - Requires Python 3 on the control node -- an additional dependency in
    air-gapped environments that may not have pip/packages available.
  - Learning curve for playbook authoring and debugging.
  - Overkill for single-node or small cluster deployments.
- **Decision**: Deferred to a future iteration. When multi-node cluster
  preparation becomes a requirement (>3 nodes, heterogeneous node roles),
  Ansible playbooks will be added under `ansible/`. For now, bash scripts
  handle single-node and simple multi-node configuration.

### Kustomize

- **Pros**: Built into kubectl (`kubectl apply -k`), no extra binary.
  Good for YAML patching and environment overlays.
- **Cons**:
  - Does not handle Helm charts natively (requires `helmChartInflationGenerator`
    which adds complexity).
  - No release management (install vs. upgrade, rollback).
  - Verbose for complex overlay hierarchies.
  - Does not handle ordering/dependencies between resources.
- **Why rejected**: Helmfile provides superior Helm release management with
  ordering, diff, and environment support. RUNE's deployment is Helm-chart-based,
  making Kustomize a poor fit.

### Fleet/Rancher GitOps

- **Pros**: Continuous reconciliation, handles configuration drift.
- **Cons**:
  - Requires a local Git server in the air-gapped environment -- significant
    additional infrastructure.
  - Complex agent-based architecture.
  - Not suitable for initial deployment (bootstrapping problem: Fleet needs
    K8s which needs images which need the registry).
- **Why rejected**: Inappropriate for air-gapped initial deployment.
  May be considered for Day 2 operations in a future iteration.

## Decision

**Layered approach: bash + Helmfile**

```
scripts/bootstrap.sh (bash)
  Phase 1: Validate prerequisites (tools, kernel, storage)
  Phase 2: Unpack OCI bundle
  Phase 3: Verify cosign signatures (fail-closed)
  Phase 4: Deploy zot registry (kubectl apply)
  Phase 5: Configure containerd mirrors
  Phase 6: Call helmfile apply

helmfile.yaml (Helmfile)
  Release 1: rune-operator (CRDs first)
  Release 2: rune-api
  Release 3: rune-ui
  Release 4: rune-docs
  Release 5: network-policies (post-deploy)
```

### Pinned versions (first release)

| Tool | Version | License |
|------|---------|---------|
| bash | System default (5.x) | GPL-3.0 (system utility) |
| Helmfile | v0.169.x | MIT |
| Helm | v3.16.x | Apache-2.0 |
| helm-diff | v3.9.x | Apache-2.0 |

## Trade-offs

**Gains**:
- Clear separation of concerns: bash handles imperative pre-K8s steps,
  Helmfile handles declarative K8s deployments.
- Minimal dependencies: bash (ubiquitous) + two static binaries (Helmfile, Helm).
- Fully auditable: bash scripts are line-by-line readable; `helmfile.yaml`
  is a single declarative file.
- Dry-run support at both layers: bash `--dry-run` flag + `helmfile diff`.
- Idempotent: bootstrap uses guard checks; Helmfile converges declaratively.

**Gives up**:
- No multi-node orchestration out of the box. Mitigated by: bash + SSH is
  sufficient for small clusters; Ansible deferred for larger deployments.
- Two tools instead of one. Mitigated by: clear phase separation means no
  overlap or confusion about which tool handles what.

**Risks**:
- bash scripts growing in complexity over time. Mitigated by: strict function
  decomposition, shellcheck enforcement, and clear phase boundaries. If
  complexity exceeds maintainability threshold, specific phases can be
  extracted to Ansible playbooks.

## Consequences

- **Bundle contents**: Helmfile and helm-diff binaries included in the bundle
  (~50 MB total). Helm is assumed present or also bundled.
- **Minimum host requirements**: bash, tar, kubectl, helm (all standard for
  K8s administration).
- **Bootstrap complexity**: Single entry point (`bootstrap.sh`), linear
  phase execution with clear progress output and fail-closed error handling.
- **Upgrade path**: `helmfile apply` handles upgrades natively (install-or-upgrade).
  Bootstrap re-run skips already-completed phases via guard checks.
- **IEC 62443 SM-10 (secure delivery)**: Both bash scripts and `helmfile.yaml`
  are version-controlled, diffable, and readable by security reviewers without
  specialized knowledge.
- **IEC 62443 SR 7.6 (security configuration)**: RBAC, NetworkPolicy, and
  security contexts are applied deterministically via Helmfile releases.
