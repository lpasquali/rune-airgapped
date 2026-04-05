# RUNE Air-Gapped Deployment

OCI bundle packaging, offline installation scripts, and network-isolated Kubernetes deployment for the RUNE platform.

## Purpose

Ship the entire RUNE ecosystem (API server, operator, UI, docs, charts) as a
self-contained OCI tarball that can be deployed to fully air-gapped Kubernetes
clusters with zero internet access.

## Scope

- **Bundle**: Package all container images, Helm charts, SBOMs, VEX documents,
  and cosign signatures into a single OCI-layout tarball.
- **Bootstrap**: Minimal shell script that unpacks the bundle, starts a local
  OCI registry (zot), verifies supply-chain integrity, and deploys via Helmfile.
- **Network Policies**: Namespace-scoped least-privilege network policies
  (Cilium/Calico) that RUNE can enforce or the customer applies on their side.
- **RBAC & Isolation**: Namespace-scoped roles, PodSecurityAdmission, resource
  quotas, and bound service account tokens.

## Architecture

```
[Build Host]                          [Air-Gapped Cluster]
                                      
  crane pull images                     tar xzf rune-bundle.tar.gz
  helm push charts to local zot         zot serve storage/
  oras push SBOMs + signatures          cosign verify --key bundled.pub
  cosign sign all artifacts             helmfile apply
  tar czf rune-bundle.tar.gz           
```

## Prerequisites (target cluster)

| Tool | Version | Purpose |
|------|---------|---------|
| `kubectl` | >= 1.27 | Cluster management |
| `helm` | >= 3.12 | Chart installation |
| `helmfile` | >= 0.158 | Declarative release management |
| containerd or CRI-O | Latest | Container runtime |
| CNI with NetworkPolicy | Cilium or Calico | Network isolation |
| `bash` + `tar` | Any | Bundle extraction |

## Security & Compliance

- IEC 62443-4-1 ML4 aligned
- SLSA Level 3 build provenance (signatures bundled offline)
- Cosign verification without internet (bundled public keys)
- SBOM and VEX documents shipped alongside every image
- Namespace isolation with PodSecurityAdmission `restricted` profile

## License

[Apache License 2.0](LICENSE)
