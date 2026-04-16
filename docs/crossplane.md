# Crossplane Infrastructure Provisioning in Airgapped Environments

## Overview

Crossplane enables declarative, Kubernetes-native infrastructure provisioning for RUNE. This guide covers deployment considerations for **partially-connected airgapped environments**.

## Deployment Models

### Model 1: Fully Disconnected (Recommended for True Airgap)

**Crossplane is NOT recommended for fully air-gapped deployments** where:
- No outbound connectivity to cloud control planes (AWS/GCP/Azure APIs)
- No external services available

**For fully disconnected deployments, use:**
- On-prem CNPG operator for PostgreSQL
- MinIO Tenant for S3-compatible object storage
- Manual Secrets or External Secrets Operator (ESO) for credential wiring

### Model 2: Partially Connected Airgap (Crossplane Use Case)

**Crossplane is useful when:**
- Cluster has network access to cloud control planes (e.g., VPN to AWS/GCP/Azure)
- Workload pods are isolated from external networks
- Infrastructure provisioning is desired as infrastructure-as-code

In this model:
1. Cluster is provisioned and imports Crossplane packages from internal registry (Zot)
2. Cluster connects outbound to cloud APIs (AWS RDS, Cloud SQL, S3, GCS, etc.)
3. Crossplane provisions resources via cloud APIs
4. Secrets written to cluster remain internal (no outbound credential exposure)

### Model 3: On-Prem Kubernetes with Crossplane (Full Local)

**Use Crossplane to manage on-prem infrastructure:**
- CNPG cluster via `provider-kubernetes` Composition
- MinIO Tenant via `provider-kubernetes` Composition
- Entirely self-contained within the cluster

This is the **same as Phase 1a** of the implementation and requires no external APIs.

## Building Airgapped Bundle with Crossplane

### Prerequisites

- `crane` installed (image pulling tool)
- Connected build host or VM with internet access
- Target airgapped environment with:
  - Zot OCI registry running (included in rune-airgapped bundle)
  - Helm installed
  - CNPG operator (if using CNPG compositions)

### Build Command

```bash
./scripts/build-bundle.sh \
  --tag v0.0.0-custom \
  --output rune-bundle-with-crossplane.tar.gz \
  --include-crossplane \
  --include-postgres
```

This bundles:
- RUNE suite images (rune, rune-operator, rune-ui, rune-audit, rune-docs)
- Infrastructure images (nginx, Zot registry)
- Optional: PostgreSQL image (for CNPG in-cluster)
- **Crossplane v2.2.0** core image
- **Crossplane functions**: patch-and-transform, go-templating, auto-ready
- **Crossplane provider**: provider-kubernetes (required for all compositions)

### Bundle Size Impact

Adding Crossplane increases bundle size by ~200-300 MB:
- Crossplane core: ~80 MB
- provider-kubernetes: ~60 MB
- Functions: ~20-30 MB each
- Helm chart for Crossplane: included in helmfile

## Deployment Workflow

### 1. Transfer Bundle to Airgapped Environment

```bash
# Copy bundle to airgapped host (USB drive, data diode, etc.)
cp rune-bundle-with-crossplane.tar.gz /media/usb-drive/
```

### 2. Extract and Load Images

```bash
# On airgapped host
cd /tmp
tar -xzf /media/usb-drive/rune-bundle-with-crossplane.tar.gz

# Load images into Zot registry
scripts/bootstrap.sh \
  --registry-host zot.registry:5000 \
  --images ./images/
```

### 3. Install Crossplane Control Plane

```bash
# Use helmfile to install Crossplane (if using on-prem CNPG/MinIO)
helmfile apply -f helmfile.yaml \
  --selector "tier=infrastructure"
```

Or manually install from bundled chart:

```bash
helm install crossplane ./charts/crossplane-v2.2.0.tgz \
  -n crossplane-system --create-namespace
```

### 4. Apply Crossplane Packages

From the bundle or from rune-charts repository:

```bash
# XRDs and Functions
kubectl apply -f /path/to/rune-charts/crossplane/xrds/
kubectl apply -f /path/to/rune-charts/crossplane/functions.yaml
kubectl apply -f /path/to/rune-charts/crossplane/providers.yaml

# RBAC for secret writing
kubectl apply -f /path/to/rune-charts/crossplane/rbac/

# ProviderConfig for in-cluster access
kubectl apply -f /path/to/rune-charts/crossplane/config/providerconfig-kubernetes.yaml

# Compositions (on-prem path only; cloud path requires credential setup)
kubectl apply -f /path/to/rune-charts/crossplane/compositions/cnpg/
kubectl apply -f /path/to/rune-charts/crossplane/compositions/minio/
```

### 5. Provision Infrastructure

For on-prem (CNPG + MinIO):

```bash
# Provision PostgreSQL via CNPG
kubectl apply -f /path/to/rune-charts/crossplane/examples/rune-database-cnpg.yaml

# Provision S3 credentials via MinIO
kubectl apply -f /path/to/rune-charts/crossplane/examples/rune-objectstore-minio.yaml
```

### 6. Deploy RUNE

```bash
helm install rune ./rune-helm-chart-v0.0.0-custom.tgz \
  -f charts/rune/values-crossplane-cnpg.yaml \
  -n rune --create-namespace
```

## Limitations and Considerations

### Cloud Compositions in Airgap

AWS/GCP/Azure Compositions **require network access to cloud APIs**:
- If your partially-connected airgap has outbound to AWS API, CloudSQL API, etc., you can use cloud compositions
- ProviderConfig must be configured with credentials (IRSA, Workload Identity, or static keys)
- Credentials must be injected into the cluster before Compositions run

Example for AWS with static credentials:

```bash
# Create AWS ProviderConfig with credentials (airgapped, so must be pre-created)
kubectl create secret generic aws-creds \
  -n crossplane-system \
  --from-literal=aws_access_key_id=... \
  --from-literal=aws_secret_access_key=...

# Apply AWS ProviderConfig that references the secret
kubectl apply -f /path/to/crossplane/config/providerconfig-aws.yaml.tmpl
```

### Provider Package Images

Crossplane provider images (e.g., `provider-kubernetes`, `provider-aws-rds`) are OCI artifacts bundled as container images. The build-bundle script includes `provider-kubernetes` only. For cloud providers, you must either:
1. Include them in the bundle at build time (increases size)
2. Pre-load them into Zot before running Crossplane

### xpkg Artifacts

Function and Provider packages are `xpkg` OCI artifacts. The build-bundle script handles them like standard container images. They are mirrored into the Zot registry by `bootstrap.sh` and referenced by Crossplane with internal registry URLs.

## On-Prem CNPG + MinIO Workflow (Simplest)

For a fully self-contained, air-gapped setup:

```bash
# 1. Build bundle with Crossplane
./scripts/build-bundle.sh \
  --tag v0.0.0 \
  --output rune-bundle-airgap.tar.gz \
  --include-crossplane

# 2. Transfer and load into airgapped environment
tar -xzf rune-bundle-airgap.tar.gz
scripts/bootstrap.sh --registry-host zot.registry:5000

# 3. Install CNPG operator
helm install cnpg cloudnative-pg/cloudnative-pg \
  -n cnpg-system --create-namespace

# 4. Install Crossplane
helm install crossplane ./charts/crossplane-v2.2.0.tgz \
  -n crossplane-system --create-namespace

# 5. Apply Crossplane packages
kubectl apply -f crossplane/xrds/
kubectl apply -f crossplane/functions.yaml
kubectl apply -f crossplane/providers.yaml
kubectl apply -f crossplane/rbac/
kubectl apply -f crossplane/config/providerconfig-kubernetes.yaml

# 6. Provision infrastructure
kubectl apply -f crossplane/examples/rune-database-cnpg.yaml
kubectl apply -f crossplane/examples/rune-objectstore-minio.yaml

# 7. Deploy RUNE
helm install rune ./rune-helm-chart-v0.0.0.tgz \
  -f charts/rune/values-crossplane-cnpg.yaml \
  -n rune --create-namespace
```

This workflow is **100% disconnected** after the initial transfer and requires no external APIs.

## Troubleshooting

### Crossplane Pods Not Starting

Check provider image availability in Zot:

```bash
curl http://zot.registry:5000/v2/_catalog
```

### Compositions Failing

Check ProviderConfig status:

```bash
kubectl describe providerconfig kubernetes-provider -n crossplane-system
```

Check Composition status:

```bash
kubectl describe runedatabase rune-main -n rune
kubectl get conditions runedatabases rune-main -n rune
```

### Secret Not Written

Verify RBAC:

```bash
kubectl get rolebinding -n rune | grep crossplane
kubectl get role -n rune | grep crossplane
```

Check provider-kubernetes pod logs:

```bash
kubectl logs -n crossplane-system \
  -l pkg.crossplane.io/provider=provider-kubernetes \
  --tail=100
```

## References

- [Crossplane Documentation](https://docs.crossplane.io/)
- [Provider Kubernetes](https://github.com/crossplane-contrib/provider-kubernetes)
- [CNPG Operator](https://cloudnative-pg.io/)
- [Phase 1a: CNPG + MinIO Compositions](https://github.com/lpasquali/rune-charts/tree/main/crossplane/compositions)
- [Epic #252: Production Airgapped Deployment](https://github.com/lpasquali/rune-docs/issues/252)

