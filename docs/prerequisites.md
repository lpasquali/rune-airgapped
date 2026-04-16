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

## External Services (Production Airgap Model)

For production airgapped deployments, the following external services are **required prerequisites** (not included in the OCI bundle):

### PostgreSQL (Database)

RUNE requires a PostgreSQL instance for persistent data storage. Choose one approach:

#### Option 1: CNPG Operator (Recommended for Kubernetes)

Deploy CloudNative PG operator on the target cluster:

```bash
# Install CNPG operator (must be done separately, not in RUNE bundle)
kubectl apply -f https://releases.cnpg.io/downloads/cnpg-1.22.0.yaml

# After operator is running, create a Postgres cluster
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: rune-postgres
  namespace: rune
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised
  postgresql:
    parameters:
      shared_preload_libraries: ''
  bootstrap:
    initdb:
      database: rune
      owner: rune
      secret:
        name: rune-db-secret
  storage:
    size: 50Gi
EOF

# Create Kubernetes Secret with connection string
kubectl create secret generic rune-db-secret \
  -n rune \
  --from-literal=username=rune \
  --from-literal=password=$(openssl rand -base64 32) \
  --from-literal=RUNE_DB_URL="postgresql://rune:$(openssl rand -base64 32)@rune-postgres-rw.rune.svc.cluster.local:5432/rune"
```

#### Option 2: External Managed Database (AWS RDS, Cloud SQL, etc.)

Provision the database outside the cluster and create a Kubernetes Secret:

```bash
# Create Secret with external database connection string
kubectl create secret generic rune-db-secret \
  -n rune \
  --from-literal=RUNE_DB_URL="postgresql://username:password@db.example.com:5432/rune"
```

**Secret format**: The `RUNE_DB_URL` must be a valid PostgreSQL connection string:
```
postgresql://username:password@hostname:port/database
```

#### Requirements

- PostgreSQL 13+ (or compatible fork)
- Database named `rune` (or configured in RUNE_DB_URL)
- User with full permissions on the `rune` database
- Network connectivity from RUNE pods to the database
- (Optional) SSL/TLS for encrypted connections

### S3-Compatible Object Storage

RUNE uses S3-compatible storage for artifact and benchmark data. Choose one approach:

#### Option 1: Minio (In-Cluster or External)

Deploy Minio as a separate service:

```bash
# Deploy Minio in the cluster (example using Helm)
helm repo add minio https://charts.min.io
helm install minio minio/minio \
  --namespace minio --create-namespace \
  --set rootUser=minioadmin \
  --set rootPassword=$(openssl rand -base64 32) \
  --set persistence.size=100Gi

# Create S3 credentials Secret
kubectl create secret generic rune-s3-secret \
  -n rune \
  --from-literal=AWS_ACCESS_KEY_ID=minioadmin \
  --from-literal=AWS_SECRET_ACCESS_KEY=$(openssl rand -base64 32) \
  --from-literal=S3_ENDPOINT=http://minio.minio.svc.cluster.local:9000 \
  --from-literal=S3_BUCKET=rune
```

#### Option 2: External S3 (AWS S3, GCS, etc.)

Use an external S3-compatible service:

```bash
# Create S3 credentials Secret
kubectl create secret generic rune-s3-secret \
  -n rune \
  --from-literal=AWS_ACCESS_KEY_ID=your-access-key \
  --from-literal=AWS_SECRET_ACCESS_KEY=your-secret-key \
  --from-literal=S3_ENDPOINT=https://s3.us-west-2.amazonaws.com \
  --from-literal=S3_BUCKET=rune-data
```

**Requirements**:
- S3-compatible endpoint (S3 API, AWS S3, GCS, Minio, etc.)
- Access credentials (access key ID + secret access key)
- Bucket created and ready
- Network connectivity from RUNE pods to the S3 endpoint
- (Optional) SSL/TLS for encrypted connections

### Tier 1 Inference Backend

RUNE Tier 1 agents require an LLM inference backend. Supported backends:

#### Option 1: Ollama (Self-Hosted)

Deploy Ollama on the cluster or externally:

```bash
# Deploy Ollama in the cluster (example)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ollama
  namespace: default
spec:
  containers:
  - name: ollama
    image: ollama/ollama:latest
    ports:
    - containerPort: 11434
    resources:
      requests:
        memory: "16Gi"
        cpu: "4"
      limits:
        memory: "32Gi"
        cpu: "8"
EOF

# Create inference endpoint Secret
kubectl create secret generic rune-inference-secret \
  -n rune \
  --from-literal=RUNE_INFERENCE_URL=http://ollama.default.svc.cluster.local:11434
```

#### Option 2: External LLM Service

Point to an external inference service (k8s-inference, text-generation-webui, etc.):

```bash
# Create inference endpoint Secret
kubectl create secret generic rune-inference-secret \
  -n rune \
  --from-literal=RUNE_INFERENCE_URL=http://inference.example.com:5000
```

**Requirements**:
- LLM inference server running with OpenAI-compatible API
- Supported models: Ollama models (llama2, mistral, etc.) for Tier 1 agents
- Network connectivity from RUNE pods to the inference endpoint
- (Optional) Authentication credentials if endpoint requires them

### Network Connectivity Matrix (Production)

| Source | Destination | Service | Port | Protocol | Purpose |
|--------|-------------|---------|------|----------|---------|
| RUNE pods | PostgreSQL endpoint | Database | 5432 (or custom) | TCP | Application data |
| RUNE pods | S3 endpoint | Object storage | 443 or 9000 | TCP (HTTPS) | Benchmark artifacts |
| RUNE pods | Inference endpoint | LLM backend | 11434 or custom | HTTP | Tier-1 agent inference |
| RUNE pods | DNS server | CoreDNS | 53 | UDP/TCP | Service discovery |

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

**Cluster & infrastructure**:
- [ ] Kubernetes cluster is running and accessible via `kubectl`
- [ ] kubectl >= 1.27.0 and helm >= 3.12.0 are installed
- [ ] Bundle tarball has been transferred and checksum verified
- [ ] Sufficient disk space for bundle extraction (~2x bundle size)
- [ ] Node resources meet the minimum requirements
- [ ] CNI plugin supports NetworkPolicy (or plan to use `--no-network-policies`)
- [ ] containerd is configured to use the in-cluster registry (or will be post-deploy)
- [ ] (Production) StorageClass available for registry PVC
- [ ] (Production) TLS certificates prepared for internal services

**External services (production)**:
- [ ] PostgreSQL instance provisioned (CNPG or managed service)
- [ ] Database created and connection string available
- [ ] S3-compatible storage configured (Minio or external)
- [ ] S3 credentials and bucket ready
- [ ] LLM inference backend running (Ollama or external)
- [ ] Network paths verified (cluster → database, S3, inference)

## Quick-Start Example (Production Airgap)

This example walks through a complete setup with external services:

### Step 1: Prepare external services (pre-deployment)

```bash
# 1. PostgreSQL (assume managed service or CNPG already running)
# Get connection string from database provider
RUNE_DB_URL="postgresql://user:pass@postgres.example.com:5432/rune"

# 2. S3-compatible storage (assume Minio or AWS S3 ready)
AWS_ACCESS_KEY_ID="your-access-key"
AWS_SECRET_ACCESS_KEY="your-secret-key"
S3_ENDPOINT="https://s3.example.com"
S3_BUCKET="rune-data"

# 3. Inference backend (assume Ollama or other service ready)
RUNE_INFERENCE_URL="http://ollama.example.com:11434"
```

### Step 2: Transfer bundle to air-gapped environment

```bash
# On connected host, build minimal bundle (no embedded services)
./scripts/build-bundle.sh \
  --tag v0.1.0 \
  --output rune-bundle-v0.1.0.tar.gz \
  --arch amd64 \
  --sign

# Transfer to air-gapped environment via approved mechanism (USB, data diode, etc.)
```

### Step 3: Create Kubernetes Secrets for external services

```bash
# In air-gapped cluster
kubectl create namespace rune

# PostgreSQL Secret
kubectl create secret generic rune-db-secret \
  -n rune \
  --from-literal=RUNE_DB_URL="postgresql://user:pass@postgres.example.com:5432/rune"

# S3 Secret
kubectl create secret generic rune-s3-secret \
  -n rune \
  --from-literal=AWS_ACCESS_KEY_ID="your-access-key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="your-secret-key" \
  --from-literal=S3_ENDPOINT="https://s3.example.com" \
  --from-literal=S3_BUCKET="rune-data"

# Inference Secret
kubectl create secret generic rune-inference-secret \
  -n rune \
  --from-literal=RUNE_INFERENCE_URL="http://ollama.example.com:11434"
```

### Step 4: Deploy RUNE with bootstrap

```bash
# Create values overlay for external services
cat > /tmp/values-prod.yaml <<EOF
postgres:
  enabled: false  # Do NOT use in-cluster Postgres

s3:
  endpoint: https://s3.example.com
  bucket: rune-data
  secretRef: rune-s3-secret

inference:
  backend: http://ollama.example.com:11434
EOF

# Run bootstrap
./scripts/bootstrap.sh \
  --bundle /path/to/rune-bundle-v0.1.0.tar.gz \
  --values /tmp/values-prod.yaml
```

### Step 5: Verify deployment

```bash
# Check all pods running
kubectl get pods -n rune

# Verify database connectivity
kubectl exec -it -n rune deployment/rune-api -- \
  psql "$RUNE_DB_URL" -c "SELECT version();"

# Verify S3 connectivity
kubectl exec -it -n rune deployment/rune-api -- \
  aws s3 ls s3://rune-data/

# Verify inference backend
kubectl exec -it -n rune deployment/rune-api -- \
  curl http://ollama.example.com:11434/api/status
```

That's it! RUNE is now deployed in air-gapped production with external services.
