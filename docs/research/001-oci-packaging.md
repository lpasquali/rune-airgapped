# ADR-001: OCI Tarball Packaging Tooling

## Status

Accepted

## Context

RUNE's air-gapped deployment requires packaging all container images, Helm charts,
SBOMs, cosign signatures, and VEX documents into a single OCI-compliant tarball.
The target environment has no internet access, so every artifact must be bundled
at build time on a connected workstation and transported physically or via
one-way data transfer.

Key constraints:

- Must produce OCI layout (not legacy Docker V2 tarballs).
- Must handle multi-arch manifests (amd64 + arm64).
- Must include cosign signatures and SBOMs as OCI artifacts alongside images.
- Must include Helm charts as OCI artifacts.
- Minimal host-side dependencies (ideally a single static binary, no Docker daemon).
- Must be scriptable for CI integration (`scripts/build-bundle.sh`).
- IEC 62443 SM-9 (provenance): signatures and attestations must be preserved in transport.

## Candidates Evaluated

| Tool | License | Type | Daemon Required | OCI Layout | Multi-arch | Helm Charts | SBOMs/Signatures | Verdict |
|------|---------|------|-----------------|------------|------------|-------------|-------------------|---------|
| **crane** (go-containerregistry) | Apache-2.0 | Single static Go binary | No | Yes (`--format=oci`) | Yes | No (images only) | Via OCI layout copy | **Selected (images)** |
| **oras** | Apache-2.0 | Single static Go binary | No | Yes | N/A | Yes (OCI artifact) | Yes (native) | **Selected (artifacts)** |
| **helm push** (built-in) | Apache-2.0 | Part of Helm CLI | No | Yes (OCI) | N/A | Yes (native) | No | **Selected (charts)** |
| skopeo | Apache-2.0 | Binary + containers/image libs | No | Yes | Yes | No | Via transport | Rejected |
| docker save | Apache-2.0 | Docker CLI | Yes (dockerd) | No (Docker V2) | Partial | No | No | Rejected |

### crane

- **Pros**: Single ~15 MB static binary with zero runtime dependencies. Produces
  native OCI layout directories. Excellent multi-arch support via manifest list
  handling. Used by ko and cosign ecosystem, ensuring compatibility with RUNE's
  signing pipeline. Composable with shell scripts. Fast parallel pulls.
- **Cons**: Does not handle Helm charts or arbitrary OCI artifacts natively --
  those require companion tooling (helm CLI, oras).

### skopeo

- **Pros**: Flexible transport model (`docker://`, `oci:`, `dir:`). Battle-tested
  in Red Hat ecosystem. Supports signing via containers/image policy.
- **Cons**: Heavier dependency chain (containers/image, containers/storage libraries).
  On some distros requires container runtime libraries. No advantage over crane
  for our use case (pure OCI layout output). Does not handle Helm charts.
- **Why rejected**: crane achieves the same OCI layout output with fewer dependencies
  and tighter integration with the cosign ecosystem RUNE already uses.

### oras

- **Pros**: Purpose-built for OCI artifacts (SBOMs, signatures, VEX documents).
  First-class support for OCI referrers API. Single static binary.
- **Cons**: Not designed for bulk container image pulls (crane is better for that).
- **Role**: Complements crane -- used for pushing/pulling non-image OCI artifacts
  (SBOMs, cosign signatures, VEX) into the staging registry.

### helm push (built-in OCI)

- **Pros**: Native Helm 3.8+ capability. Zero extra tooling for chart packaging.
  `helm push chart.tgz oci://registry/repo` works directly with OCI registries.
- **Cons**: Only handles Helm charts.
- **Role**: Complements crane -- used specifically for chart OCI artifacts.

### docker save

- **Pros**: Zero extra tools if Docker is already installed.
- **Cons**: Produces Docker V2 tarballs, not OCI layout. Requires a running Docker
  daemon. Legacy format requires conversion for OCI-native registries. No native
  multi-arch support (saves only the local platform).
- **Why rejected**: Violates OCI-native requirement. Requires daemon. Legacy format
  creates unnecessary conversion complexity.

## Decision

Use a **composite toolchain**:

1. **crane** for container image pulls into OCI layout.
2. **helm push** for Helm chart packaging as OCI artifacts.
3. **oras** for SBOM, cosign signature, and VEX document artifact handling.
4. **Local zot staging registry** as the assembly target -- all tools push into
   a local zot instance, then the zot storage directory is tarred as the final bundle.

The build pipeline (`scripts/build-bundle.sh`) will:

```
crane pull --format=oci <image> → push to local zot
helm push <chart>.tgz oci://localhost:5000/rune-charts
oras push localhost:5000/rune/<image>:sha256-<digest>.sbom ./sbom.json
tar czf rune-airgapped-bundle.tar.gz zot-storage/
```

### Pinned versions (first release)

| Tool | Version | SHA256 |
|------|---------|--------|
| crane | v0.20.x | (pin at build time) |
| oras | v1.2.x | (pin at build time) |
| helm | v3.16.x | (pin at build time) |

## Trade-offs

**Gains**:
- Pure OCI layout throughout -- no format conversion at any stage.
- Each tool is best-in-class for its artifact type.
- All tools are single static binaries with Apache-2.0 licenses.
- Tight integration with cosign signing and verification pipeline.

**Gives up**:
- Three CLI tools instead of one. Mitigated by: all are static binaries,
  easily vendored, and `scripts/prerequisites.sh` validates their presence.
- No single-command "bundle everything" tool. Mitigated by: `build-bundle.sh`
  orchestrates all steps.

**Risks**:
- Tool version drift between build and deploy environments. Mitigated by:
  pinning versions in `scripts/prerequisites.sh` and including tool binaries
  in the bundle itself.

## Consequences

- **Bundle size**: OCI layout is slightly larger than compressed Docker V2 tarballs
  (~5-10% overhead). Acceptable given correctness and verifiability benefits.
- **Minimum build host requirements**: Linux/macOS with ~200 MB disk for tool binaries.
  No Docker daemon required.
- **Bootstrap complexity**: Low -- three static binaries plus bash.
- **CI integration**: All tools support non-interactive, scriptable operation.
  Build pipeline is a single bash script.
- **IEC 62443 SM-9**: Cosign signatures and SBOM attestations travel alongside
  images in the same OCI layout, enabling offline provenance verification.
