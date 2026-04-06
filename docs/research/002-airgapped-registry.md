# ADR-002: Air-Gapped OCI Registry

## Status

Accepted

## Context

The air-gapped Kubernetes cluster needs a lightweight OCI registry to serve
container images, Helm charts, SBOMs, and cosign signatures from the unpacked
bundle. The registry is the single distribution point for all artifacts inside
the air-gap boundary.

Key constraints:

- Must serve directly from an unpacked OCI layout directory (no import step).
- Minimal resource footprint (runs as a Pod alongside RUNE workloads).
- Must support OCI referrers API for discovering attached SBOMs and signatures.
- Must support cosign signature verification.
- Must support TLS for in-cluster image pulls (containerd requires HTTPS or
  explicit insecure mirror config).
- IEC 62443 SR 5.1 (network segmentation): registry runs in its own namespace
  (`rune-registry`) with restricted network access.
- Portable across K8s distributions (vanilla K8s, k3s, RKE2, EKS-Anywhere).

## Candidates Evaluated

| Tool | License | CNCF Status | Binary Size | OCI Native | Direct Serve | Referrers API | Verdict |
|------|---------|-------------|-------------|------------|--------------|---------------|---------|
| **zot** | Apache-2.0 | Sandbox | ~20 MB | Yes | Yes | Yes | **Selected** |
| distribution | Apache-2.0 | Graduated (Docker ecosystem) | ~30 MB | No (converts) | No (import) | Partial | Rejected |
| Harbor | Apache-2.0 | Graduated | ~500 MB+ (multi-component) | No | No | Yes | Rejected |
| k3s embedded | Apache-2.0 | N/A (k3s-specific) | N/A | No | N/A | No | Rejected |
| Dragonfly | Apache-2.0 | Incubating | ~100 MB+ | No | No | No | Rejected |

### zot

- **Pros**:
  - Single ~20 MB static binary. Minimal attack surface.
  - OCI-native from the ground up -- serves OCI layout directories directly
    without any import or conversion step. Unpack tarball, point zot at the
    directory, it serves immediately.
  - Built-in storage integrity scrubbing (detects corrupt blobs).
  - Supports OCI referrers API (cosign signatures, SBOMs discoverable via tag
    or referrers endpoint).
  - Supports cosign signature verification at push time (optional policy).
  - Single configuration file, straightforward TLS setup.
  - CNCF Sandbox project with active development and growing adoption.
  - Resource consumption: ~30 MB RAM idle, ~100 MB under load.
- **Cons**:
  - Younger project with a smaller community than distribution.
  - No built-in vulnerability scanning (not needed -- RUNE uses Grype separately).
  - No multi-tenant RBAC (not needed -- single-tenant air-gapped cluster).

### distribution (Docker Registry v2)

- **Pros**: CNCF Graduated, battle-tested, widely deployed, extensive documentation,
  large community.
- **Cons**:
  - Not OCI-native: stores blobs in its own internal format, requires an import
    step from OCI layout (e.g., `crane push` or `skopeo copy`). This adds
    complexity and time to the bootstrap process.
  - Heavier configuration (YAML with many optional sections).
  - OCI referrers API support is partial/experimental.
- **Why rejected**: The import step is a significant disadvantage in air-gapped
  environments where bootstrap simplicity is critical. zot's ability to serve
  directly from unpacked OCI layout eliminates an entire phase of the bootstrap.

### Harbor

- **Pros**: Feature-rich enterprise registry with RBAC, replication, vulnerability
  scanning (built-in Trivy), audit logging, multi-tenant support.
- **Cons**:
  - Requires PostgreSQL and Redis as backing services. Total footprint is ~500 MB+
    of container images and significant CPU/memory overhead.
  - Complex deployment (Helm chart with many sub-charts).
  - Overkill for a single-tenant air-gapped deployment of a specific application.
- **Why rejected**: Resource footprint and operational complexity are disproportionate
  to the requirement (serve a fixed set of artifacts to a single cluster).

### k3s/RKE2 embedded registry

- **Pros**: Zero extra infrastructure if running k3s.
- **Cons**:
  - k3s-only -- not portable across K8s distributions.
  - Limited to containerd mirror/cache, not a full OCI registry.
  - Cannot serve Helm charts or OCI artifacts (images only).
  - No referrers API, no cosign signature support.
- **Why rejected**: Not portable. Does not meet OCI artifact requirements.

### Dragonfly

- **Pros**: Excellent P2P distribution for large multi-node clusters.
- **Cons**:
  - Complex multi-component architecture (manager, scheduler, dfdaemon).
  - Designed for large-scale distribution, not small air-gapped clusters.
  - No direct OCI layout serving capability.
- **Why rejected**: Overkill for initial deployment scope (single cluster, <20 nodes).

## Decision

**zot** as the air-gapped OCI registry.

Deployed as a Kubernetes Deployment in the `rune-registry` namespace, with the
unpacked OCI bundle mounted as a PersistentVolume.

### Deployment architecture

```
PersistentVolume (hostPath or local)
  └── zot-storage/        (unpacked from rune-airgapped-bundle.tar.gz)
      ├── rune/api/       (OCI layout)
      ├── rune/operator/  (OCI layout)
      ├── rune/ui/        (OCI layout)
      └── rune-charts/    (OCI layout)

Namespace: rune-registry
  └── Deployment: zot (1 replica)
      ├── Volume mount: /var/lib/zot → PV
      ├── Port: 5000 (HTTPS)
      └── TLS: self-signed cert (generated during bootstrap)

Service: zot.rune-registry.svc.cluster.local:5000
```

### Pinned version (first release)

| Tool | Version |
|------|---------|
| zot | v2.1.x |

## Trade-offs

**Gains**:
- Zero-import bootstrap: unpack tarball, start zot, images are immediately pullable.
- Minimal footprint: ~20 MB binary, ~30 MB RAM idle.
- OCI-native: full referrers API support for SBOM and signature discovery.
- Simple configuration: single JSON config file.

**Gives up**:
- Smaller community than distribution. Mitigated by: CNCF Sandbox status and
  active development. zot's scope is narrow (OCI registry), reducing risk of
  abandonment.
- No built-in vulnerability scanning. Mitigated by: RUNE uses Grype/Trivy
  independently; bundled VEX documents provide offline vulnerability context.
- No multi-tenant RBAC. Mitigated by: single-tenant deployment; NetworkPolicy
  provides access control at the network layer.

**Risks**:
- zot API compatibility changes between minor versions. Mitigated by: pinning
  to a specific version in the bundle and testing upgrades explicitly.

## Consequences

- **Bundle size**: zot binary (~20 MB) included in the bundle. Negligible overhead.
- **Minimum cluster requirements**: ~100 MB RAM for zot pod, ~50m CPU idle.
  PersistentVolume sized to bundle contents (typically 2-5 GB).
- **Bootstrap complexity**: Phase 4 of bootstrap is: create namespace, apply
  zot deployment manifest, wait for ready. ~10 lines of bash.
- **Containerd configuration**: All cluster nodes need containerd mirror config
  pointing to `zot.rune-registry.svc.cluster.local:5000`. Bootstrap handles
  this via `scripts/configure-containerd-mirrors.sh`.
- **IEC 62443 SR 5.1**: zot runs in an isolated namespace with NetworkPolicy
  allowing only ingress on port 5000. Minimal attack surface (single binary,
  no shell, no package manager in container image).
- **IEC 62443 SM-9**: Cosign signatures stored as OCI referrers are served by
  zot and verifiable offline via `cosign verify --key`.
