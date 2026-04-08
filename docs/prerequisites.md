# Prerequisites

This document lists the hardware, software, network, and Kubernetes
requirements for deploying RUNE in an air-gapped environment.

## Hardware Requirements

### Minimum (Single-Node Evaluation)

| Resource | Minimum |
|---|---|
| CPU | 4 cores |
| RAM | 16 GB |
| Disk | 50 GB free (bundle extraction + registry storage) |

### Recommended (Production)

| Resource | Recommended |
|---|---|
| CPU | 8+ cores |
| RAM | 32 GB |
| Disk | 100 GB SSD (registry PVC + application data) |
| Nodes | 3+ (for high availability) |

### With Ollama (LLM Inference)

If the bundle includes the Ollama image for local LLM inference, additional
resources are required:

| Resource | Minimum |
|---|---|
| CPU | 8 cores (16 recommended) |
| RAM | 32 GB (64 GB recommended) |
| GPU | Optional but strongly recommended for performance |
| Disk | Additional 20-50 GB for model weights |

## Software Requirements

### Build Host (Connected)

These tools are required on the machine that builds the bundle:

| Tool | Minimum Version | Purpose |
|---|---|---|
| `crane` | any recent | Pull OCI images as OCI layout |
| `helm` | 3.12.0 | Pull Helm charts from OCI registry |
| `cosign` | 2.x (optional) | Sign images for supply chain integrity |
| `tar` | any | Package the bundle tarball |
| `sha256sum` | any | Generate integrity checksums |

### Target Host (Air-Gapped)

These tools are required on the machine(s) in the air-gapped environment:

| Tool | Minimum Version | Purpose |
|---|---|---|
| `kubectl` | 1.27.0 | Kubernetes cluster management |
| `helm` | 3.12.0 | Deploy Helm charts |
| `tar` | any | Unpack the bundle tarball |
| `bash` | 4.x | Run the bootstrap script |
| `crane` | any recent (optional) | Load OCI images into registry |
| `cosign` | 2.x (optional) | Verify image signatures |

### Operating System

The bootstrap script is tested on:

- Ubuntu 22.04 LTS / 24.04 LTS
- RHEL 8.x / 9.x
- Any Linux distribution with bash 4+ and the tools listed above

### Container Runtime

- **containerd** >= 1.7.0 (required for Kubernetes)
- containerd must be configured to pull from the in-cluster registry. See
  [Containerd Mirror Configuration](#containerd-mirror-configuration) below.

## Network Requirements

### External Connectivity

**None required.** The entire deployment is designed to operate without
internet access. All container images, Helm charts, and compliance artifacts
are included in the bundle.

### Internal Connectivity

The following internal network paths must be open:

| Source | Destination | Port | Protocol | Purpose |
|---|---|---|---|---|
| Nodes | Kubernetes API server | 443/TCP | HTTPS | Cluster management |
| All RUNE pods | Zot registry | 5000/TCP | HTTP(S) | Image pulls |
| rune-ui | rune-api | 8080/TCP | HTTP | UI-to-API communication |
| rune-operator | rune-api | 8080/TCP | HTTP | Operator-to-API communication |
| rune-operator | Kubernetes API | 443/TCP | HTTPS | CRD management |
| rune-api | Ollama (if deployed) | 11434/TCP | HTTP | LLM inference |
| rune-api | SeaweedFS (if deployed) | 8333/TCP | HTTP | S3-compatible storage |
| All pods | kube-dns | 53/UDP,TCP | DNS | Service discovery |

### DNS

Kubernetes CoreDNS must be operational. RUNE services are accessed by their
cluster-internal DNS names (e.g., `zot.rune-registry.svc.cluster.local`).

## Kubernetes Cluster Requirements

### Version

Kubernetes >= 1.27.0

### Pod Security Admission (PSA)

The bootstrap script applies PSA labels to all RUNE namespaces:

```
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
```

The `restricted` profile requires:
- Containers run as non-root
- No privilege escalation
- Read-only root filesystem
- All capabilities dropped
- Seccomp profile set to `RuntimeDefault`

Ensure your cluster supports and enforces PSA at the namespace level.

### Storage

- **Default**: The Zot registry uses `emptyDir` (ephemeral, lost on pod restart).
  Suitable for evaluation.
- **Production**: Provide a StorageClass that supports `ReadWriteOnce` PVCs.
  The registry requires at least 10 Gi for image storage.

### Resource Quotas

The bootstrap script applies the following ResourceQuotas:

| Namespace | CPU Requests | CPU Limits | Memory Requests | Memory Limits | Max Pods | Max PVCs |
|---|---|---|---|---|---|---|
| `rune` | 4 | 8 | 8 Gi | 16 Gi | 20 | 5 |
| `rune-system` | 2 | 4 | 4 Gi | 8 Gi | 10 | 2 |
| `rune-registry` | 2 | 4 | 4 Gi | 8 Gi | 5 | 3 |

Ensure your cluster nodes can satisfy these quotas. Use `--no-resource-quotas`
to skip quota enforcement if you manage quotas externally.

### RBAC

The bootstrap script creates dedicated ServiceAccounts with minimal
permissions for each component. Cluster-level permissions are not required for
the application workloads. The operator requires access to the Kubernetes API
for CRD management.

### Network Policies

A CNI plugin that supports NetworkPolicy is required for the default-deny
security posture. Supported CNI plugins:

- Calico (enhanced policies included in `manifests/network-policies/calico/`)
- Cilium (enhanced policies included in `manifests/network-policies/cilium/`)
- Any CNI that implements the `networking.k8s.io/v1` NetworkPolicy API

Use `--no-network-policies` if your CNI does not support NetworkPolicy or if
you manage network segmentation externally.

## Containerd Mirror Configuration

To allow Kubernetes nodes to pull images from the in-cluster Zot registry,
configure containerd on each node. This is typically done before running the
bootstrap script.

### For containerd >= 1.7 (hosts.d style)

Create `/etc/containerd/certs.d/rune-registry.rune-registry.svc:5000/hosts.toml`:

```toml
server = "http://rune-registry.rune-registry.svc:5000"

[host."http://rune-registry.rune-registry.svc:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

If the registry uses TLS with a private CA, replace `skip_verify = true` with:

```toml
[host."https://rune-registry.rune-registry.svc:5000"]
  capabilities = ["pull", "resolve"]
  ca = "/etc/containerd/certs.d/rune-registry.rune-registry.svc:5000/ca.crt"
```

Restart containerd after configuration changes:

```bash
sudo systemctl restart containerd
```

## Pre-Deployment Checklist

- [ ] Kubernetes cluster is running and accessible via `kubectl`
- [ ] kubectl >= 1.27.0 and helm >= 3.12.0 are installed
- [ ] Bundle tarball has been transferred and checksum verified
- [ ] Sufficient disk space for bundle extraction (~2x bundle size)
- [ ] Node resources meet the minimum requirements
- [ ] CNI plugin supports NetworkPolicy (or plan to use `--no-network-policies`)
- [ ] containerd is configured to use the in-cluster registry (or will be post-deploy)
- [ ] (Production) StorageClass available for registry PVC
- [ ] (Production) TLS certificates prepared for internal services
