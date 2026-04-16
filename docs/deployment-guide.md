# RUNE Air-Gapped Deployment Guide

This guide covers the end-to-end process for deploying RUNE in an air-gapped
Kubernetes environment. For hardware, software, and network requirements, see
[Prerequisites](prerequisites.md). For architecture details, see
[Architecture](architecture.md).

## Overview

Air-gapped deployment uses a self-contained OCI bundle that includes all
container images, Helm charts, compliance artifacts, and integrity checksums.
The `bootstrap.sh` script is the single entry point. It unpacks the bundle,
verifies supply chain integrity, deploys a local OCI registry (Zot), loads
images, and installs RUNE components via Helm.

## 1. Bundle Acquisition and Verification

### Obtaining the Bundle

The bundle is built on a connected workstation using `build-bundle.sh` and
transferred to the air-gapped environment via approved media (USB, DVD, or
one-way data diode).

**Production deployment** (recommended):
```bash
# Default bundle: RUNE suite only (no bundled data-plane services)
./scripts/build-bundle.sh \
  --tag v0.0.0a2 \
  --output rune-bundle-v0.0.0a2.tar.gz \
  --arch amd64 \
  --sign
```

**Development/lab** (with optional PostgreSQL):
```bash
./scripts/build-bundle.sh \
  --tag v0.0.0a2 \
  --output rune-bundle-v0.0.0a2.tar.gz \
  --arch amd64 \
  --include-postgres \
  --sign
```

Bundle flags:

| Flag | Description |
|---|---|
| `--tag` | RUNE version tag (required) |
| `--output` | Output tarball path (required) |
| `--arch` | Target architectures, comma-separated (default: `amd64,arm64`) |
| `--include-postgres` | (Optional) Include PostgreSQL image for in-cluster deployments (dev/lab only) |
| `--include-ollama` | (Optional) Include Ollama inference server image |
| `--include-seaweedfs` | (Optional) Include SeaweedFS S3-compatible storage image |
| `--sign` | Sign images with cosign (requires `COSIGN_KEY` env or `--cosign-key`) |
| `--dry-run` | List bundle contents without pulling anything |

**Default bundle contents**: RUNE suite (rune, rune-operator, rune-ui) + infrastructure (nginx, Zot registry).

**Optional images** (dev/lab): PostgreSQL (via `--include-postgres`), Ollama, SeaweedFS. When included, `build-bundle.sh` resolves the image to an OCI digest via `crane`, pulls that pinned reference, and writes `images/<service>/bundle-meta.json` with source tag, digest, license, and provenance. The same fields are merged into `manifest.json`.

### Verifying the Bundle

Before deployment, verify the bundle checksum against the value published in
the release notes or provided out-of-band:

```bash
sha256sum rune-bundle-v0.0.0a2.tar.gz
# Compare the output against the published checksum
```

The bootstrap script performs additional verification automatically (SHA256SUMS
inside the bundle, and cosign signature verification if `cosign.pub` is
present).

### Transferring to the Air-Gapped Environment

Copy the tarball to the target host using your organization's approved
transfer mechanism. The bundle is a single `.tar.gz` file, typically 2-5 GB
depending on included optional images.

## 2. Single-Node Quickstart

This is the fastest path to a running RUNE instance. Suitable for evaluation,
development, or small-scale deployments.

### Step 1: Verify prerequisites

```bash
kubectl version --client
helm version --short
kubectl cluster-info
```

Minimum versions: kubectl >= 1.27.0, Helm >= 3.12.0. The cluster must be
reachable via `kubectl`. See [Prerequisites](prerequisites.md) for full
details.

### Step 2: Run the bootstrap

```bash
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz
```

This uses the default namespaces (`rune`, `rune-registry`, `rune-system`) and
applies all security controls (RBAC, NetworkPolicies, ResourceQuotas, PSA
labels).

### Step 3: Verify deployment

```bash
kubectl get pods -n rune
kubectl get pods -n rune-system
kubectl get pods -n rune-registry
```

All pods should be in `Running` state. The bootstrap script runs its own
validation phase, but manual verification is recommended.

## 3. Multi-Node Deployment

For production clusters with multiple nodes, the process is identical to the
single-node quickstart. The bootstrap script does not make assumptions about
cluster topology. Key considerations:

- **Storage**: The Zot registry uses `emptyDir` with a 10Gi size limit by
  default. For persistent storage across node restarts, provide a custom values
  file that configures a PersistentVolumeClaim.
- **Node affinity**: Use a custom values file to pin the registry to a
  specific node if needed.
- **Replicas**: Production values (`values/production.yaml`) set `replicaCount: 2`
  for RUNE components.

```bash
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz \
  --values /path/to/custom-values.yaml
```

## 4. Bootstrap Options Reference

```
Usage: bootstrap.sh [OPTIONS]

Required:
  --bundle FILE              Path to RUNE bundle tarball

Optional:
  --namespace NS             Application namespace (default: rune)
  --registry-namespace NS    Registry namespace (default: rune-registry)
  --operator-namespace NS    Operator namespace (default: rune-system)
  --dry-run                  Preview deployment plan without making changes
  --skip-verify              Skip cosign signature verification (not recommended)
  --registry-only            Only deploy the registry (for custom pipelines)
  --no-network-policies      Skip NetworkPolicy application
  --no-resource-quotas       Skip ResourceQuota application
  --values FILE              Custom Helm values overlay file
  --verbose                  Enable verbose output

Exit codes:
  0  All phases completed successfully
  1  Error during deployment
  2  Prerequisites missing (no changes made)
  3  Verification failed (no changes made)
```

### Dry-Run Mode

Preview the deployment plan before making any changes:

```bash
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz \
  --dry-run
```

## 5. Post-Deployment Validation

### Verify all pods are running

```bash
kubectl get pods -A -l app.kubernetes.io/part-of=rune
```

### Verify the registry is serving images

```bash
kubectl port-forward -n rune-registry svc/zot 5000:5000 &
curl http://localhost:5000/v2/_catalog
```

### Verify the API server health

```bash
kubectl port-forward -n rune svc/rune-api 8080:8080 &
curl http://localhost:8080/healthz
```

### Verify NetworkPolicies are active

```bash
kubectl get networkpolicies -A -l app.kubernetes.io/part-of=rune
```

### Verify ResourceQuotas

```bash
kubectl describe resourcequota -n rune
kubectl describe resourcequota -n rune-system
kubectl describe resourcequota -n rune-registry
```

## 6. TLS Configuration

By default, TLS is disabled for internal services. For production deployments,
enable TLS in your values overlay:

```yaml
global:
  tls:
    enabled: true
```

### Providing Certificates

Certificates must be provisioned before deployment since the cluster has no
access to external certificate authorities. Options:

1. **Pre-created Kubernetes Secrets**: Create TLS secrets in each namespace
   before running bootstrap.

   ```bash
   kubectl create secret tls rune-tls \
     --cert=server.crt \
     --key=server.key \
     -n rune
   ```

2. **Custom CA**: Generate a CA certificate and distribute it to all nodes.
   Configure containerd to trust the CA for registry communication.

3. **Registry TLS**: To secure the Zot registry with TLS, mount certificates
   into the Zot configuration. Update the registry config to use HTTPS:

   ```json
   {
     "http": {
       "address": "0.0.0.0",
       "port": "5000",
       "tls": {
         "cert": "/etc/zot/tls/tls.crt",
         "key": "/etc/zot/tls/tls.key"
       }
     }
   }
   ```

### Configuring containerd for Registry TLS

If the registry uses a self-signed or private CA certificate, configure
containerd on each node to trust it. See
[Troubleshooting](troubleshooting.md#tls-certificate-issues) for details.

## 7. Upgrading

### Standard Upgrade

1. Build a new bundle with the target version tag.
2. Transfer the bundle to the air-gapped environment.
3. Run bootstrap with the new bundle. Helm `upgrade --install` is idempotent
   and will upgrade existing releases.

```bash
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.0.0a3.tar.gz
```

### Pre-Upgrade Checklist

- Back up any persistent data (PVCs, ConfigMaps) before upgrading.
- Review release notes for breaking changes.
- Run `--dry-run` first to preview the upgrade plan.
- Verify the new bundle's SHA256 checksum.

## 8. Rollback

Helm retains release history, so rollback is straightforward:

```bash
# List release history
helm history rune -n rune
helm history rune-operator -n rune-system
helm history rune-ui -n rune

# Rollback to a previous revision
helm rollback rune <REVISION> -n rune
helm rollback rune-operator <REVISION> -n rune-system
helm rollback rune-ui <REVISION> -n rune
```

If the registry images for the previous version are no longer available, you
must re-deploy the old bundle first:

```bash
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz \
  --registry-only
```

Then perform the Helm rollback.

## 9. PostgreSQL (optional, development/lab only)

**Production deployments** should use an externally provisioned PostgreSQL instance (CNPG, managed database, or customer-operated). Configure via the `RUNE_DB_URL` Secret. See [docs/prerequisites.md](prerequisites.md) for database setup examples.

**For development/lab** environments that need an in-cluster PostgreSQL:

1. Build the bundle with `--include-postgres`:
   ```bash
   ./scripts/build-bundle.sh \
     --tag v0.0.0a2 \
     --output rune-bundle-v0.0.0a2.tar.gz \
     --include-postgres \
     --arch amd64
   ```

2. Confirm the bundle contains the PostgreSQL image:
   ```bash
   ./scripts/build-bundle.sh \
     --tag v0.0.0a2 \
     --output /tmp/test.tar.gz \
     --include-postgres \
     --dry-run | grep postgres
   ```

3. After bootstrap, the registry hosts the postgres image as **`postgres:latest`**. Enable the PostgreSQL subchart in your Helm values:

   ```yaml
   postgres:
     enabled: true
     image:
       repository: rune-registry.rune-registry.svc:5000/postgres
       tag: latest
   ```

4. Pass your overlay when bootstrapping:

   ```bash
   ./scripts/bootstrap.sh \
     --bundle /path/to/rune-bundle-v0.0.0a2.tar.gz \
     --values /path/to/values-with-postgres.yaml
   ```

5. For auditing, open `manifest.json` in the unpacked bundle (or tarball) and locate the `postgres` image entry for `source_ref`, `digest`, `license`, and `provenance`, or read `images/postgres/bundle-meta.json` directly.

### External PostgreSQL (production path)

If using an external database, leave `postgres.enabled` false and configure:
- `RUNE_DB_URL`: Kubernetes Secret with connection string (e.g., `postgresql://user:pass@postgres.example.com:5432/rune`)
- See rune-charts for the exact value paths for your version
