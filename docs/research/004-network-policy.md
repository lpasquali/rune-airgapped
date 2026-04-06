# ADR-004: NetworkPolicy Enforcement

## Status

Accepted

## Context

RUNE's air-gapped deployment requires namespace-scoped least-privilege network
segmentation. IEC 62443 SR 5.1 (network segmentation) and SR 5.2 (zone boundary
protection) mandate demonstrable isolation between security zones.

RUNE's namespace topology defines three zones:

| Namespace | Role | Zone |
|-----------|------|------|
| `rune-system` | Operator (needs K8s API access) | Management |
| `rune` | API server, UI, docs (inter-pod + external services) | Application |
| `rune-registry` | zot registry (all namespaces pull from here) | Infrastructure |

Required network policies:

1. Default deny ingress + egress per namespace.
2. Allow `rune-api` <-- `rune-ui` (HTTP 8080).
3. Allow `rune-api` <-- `rune-operator` (HTTP 8080, cross-namespace).
4. Allow `rune-api` --> ollama (HTTP 11434, may be external).
5. Allow `rune-api` --> S3/SeaweedFS (HTTP 8333).
6. Allow all --> `rune-registry` (HTTPS 5000, image pulls).
7. Allow `rune-operator` --> K8s API (HTTPS 443).
8. Deny all other traffic.

Key constraints:

- Must work on any Kubernetes distribution with a CNI that supports NetworkPolicy.
- Customer may enforce their own policies -- RUNE's policies must be additive,
  not conflicting.
- IEC 62443 requires demonstrable zone boundaries mapped to specific policies.
- Portable across vanilla K8s, k3s, RKE2, EKS-Anywhere, OpenShift.

## Candidates Evaluated

| Tool | License | CNCF Status | Policy Model | L7 Support | eBPF Required | Verdict |
|------|---------|-------------|--------------|------------|---------------|---------|
| **Cilium** | Apache-2.0 | Graduated | K8s NetworkPolicy + CiliumNetworkPolicy CRD | Yes (HTTP, DNS, gRPC) | Yes (kernel >= 4.19) | **Recommended (enhanced)** |
| Calico | Apache-2.0 | CNCF project | K8s NetworkPolicy + GlobalNetworkPolicy CRD | Limited | Optional (eBPF or iptables) | Alternative |
| Vanilla K8s NetworkPolicy | N/A (built-in) | N/A | K8s NetworkPolicy | No (L3/L4 only) | No | **Baseline (portable)** |

### Cilium

- **Pros**:
  - CNCF Graduated. Most capable CNI for network security.
  - eBPF-based: higher performance than iptables, kernel-level enforcement.
  - L7 policy support: can enforce HTTP method/path rules at zone boundaries
    (e.g., allow only `GET /healthz` from monitoring, allow only `POST /api/v1/`
    from UI). This directly strengthens IEC 62443 SR 5.2 conduit modeling.
  - DNS-aware policies: can restrict egress by FQDN, not just IP.
  - Hubble observability: real-time flow visibility for audit and troubleshooting.
  - Replaces kube-proxy: fewer components, simpler network stack.
  - `CiliumNetworkPolicy` CRD is a superset of K8s NetworkPolicy.
- **Cons**:
  - Requires eBPF support (kernel >= 4.19, which is standard on any
    modern Linux distribution).
  - Heavier than Calico for simple L3/L4 use cases (~200 MB RAM per node).
  - Must be included in the air-gapped bundle (Cilium container images).
  - Not every customer cluster will have Cilium as their CNI.

### Calico

- **Pros**:
  - Widely deployed, works in both iptables and eBPF modes.
  - Supports both standard K8s NetworkPolicy and extended `GlobalNetworkPolicy` CRD.
  - Lighter resource footprint than Cilium in iptables mode.
  - `NetworkSet` and `GlobalNetworkSet` CRDs for defining external endpoints.
- **Cons**:
  - Less L7 capability than Cilium (limited HTTP-level enforcement).
  - Multiple components (Felix, BIRD/Typha) add operational complexity.
  - eBPF mode is newer and less battle-tested than Cilium's.
- **Why not primary**: Calico is a strong alternative, but Cilium's L7 capabilities
  and CNCF Graduated status make it the better fit for IEC 62443 zone/conduit
  modeling. Calico remains a supported alternative.

### Vanilla Kubernetes NetworkPolicy

- **Pros**:
  - Built-in to Kubernetes. No extra CRDs or CNI-specific dependencies.
  - Portable across any CNI that implements the NetworkPolicy spec
    (Cilium, Calico, Weave, Flannel with network policy support, etc.).
  - Simple, well-documented, understood by all K8s administrators.
- **Cons**:
  - L3/L4 only: no HTTP path/method filtering, no DNS-aware rules.
  - No default deny-all-egress without explicit policy per namespace.
  - Cannot express "deny all except DNS" cleanly (must enumerate kube-dns IP).
  - Insufficient alone for IEC 62443 SR 5.2 (zone boundary protection requires
    deeper inspection than IP + port).
- **Role**: Baseline policies shipped with every deployment. Provides minimum
  viable network segmentation regardless of CNI.

## Decision

**Dual-layer approach: vanilla K8s NetworkPolicy (baseline) + Cilium CiliumNetworkPolicy (enhanced)**

### Layer 1: Portable Baseline (always shipped)

Standard Kubernetes NetworkPolicy manifests in `manifests/network-policies/baseline/`:

- `default-deny.yaml` -- default deny ingress + egress per namespace.
- `rune-api-ingress.yaml` -- allow UI and operator to reach API.
- `rune-api-egress.yaml` -- allow API to reach Ollama, S3, DNS.
- `rune-registry-ingress.yaml` -- allow all namespaces to pull images.
- `rune-operator-egress.yaml` -- allow operator to reach K8s API.
- `dns-egress.yaml` -- allow all pods to reach kube-dns.

These work with **any** CNI that supports NetworkPolicy (Cilium, Calico, Flannel
with network policy, etc.).

### Layer 2: Enhanced (optional, requires Cilium)

CiliumNetworkPolicy manifests in `manifests/network-policies/cilium/`:

- L7 HTTP rules restricting API paths at zone boundaries.
- DNS-aware egress rules (FQDN-based instead of IP-based).
- Hubble flow logging for audit trail.

Applied only when Cilium is detected as the cluster CNI. Bootstrap script checks:
```bash
if kubectl get crd ciliumnetworkpolicies.cilium.io &>/dev/null; then
  kubectl apply -f manifests/network-policies/cilium/
fi
```

### IEC 62443 Zone/Conduit Mapping

| Zone | Namespace | Boundary Enforcement |
|------|-----------|---------------------|
| Management | `rune-system` | Egress to K8s API only (443/TCP). Ingress denied. |
| Application | `rune` | Ingress from UI/operator on 8080/TCP. Egress to Ollama (11434/TCP), S3 (8333/TCP), DNS. |
| Infrastructure | `rune-registry` | Ingress from all on 5000/TCP. Egress denied. |
| External | Outside cluster | All traffic denied except explicitly allowed conduits. |

Each conduit (arrow between zones) maps to a specific NetworkPolicy rule.
The baseline layer enforces L3/L4 boundaries. The Cilium layer adds L7
inspection at conduit boundaries where IEC 62443 SR 5.2 requires deeper
verification.

### Pinned versions

| Tool | Version | Notes |
|------|---------|-------|
| Cilium | v1.16.x | Included in bundle only for Cilium-enhanced deployments |
| K8s NetworkPolicy | v1 | Stable API, no version concerns |

## Trade-offs

**Gains**:
- Portable baseline works on any K8s distribution with any NetworkPolicy-capable CNI.
- Enhanced Cilium layer provides L7 enforcement for stronger IEC 62443 compliance.
- Customer-managed policy integration: RUNE's policies are namespace-scoped and
  additive -- they do not conflict with cluster-wide policies.
- Clear zone/conduit mapping satisfies IEC 62443 audit requirements.

**Gives up**:
- Full L7 enforcement requires Cilium, which not every customer will have.
  Mitigated by: baseline layer provides L3/L4 isolation that satisfies minimum
  requirements; Cilium is recommended but not mandatory.
- Cilium images must be included in the bundle for enhanced deployments (~500 MB).
  Mitigated by: optional -- only included when customer requests Cilium-enhanced
  deployment profile.

**Risks**:
- Customer's existing CNI may not support NetworkPolicy at all (e.g., bare Flannel
  without network policy plugin). Mitigated by: `scripts/prerequisites.sh` checks
  for NetworkPolicy support and warns if absent. Bootstrap fails closed if
  network policy validation fails.
- Policy conflicts with customer-managed policies. Mitigated by: RUNE policies are
  namespace-scoped (not cluster-scoped), using labels specific to RUNE workloads.

## Consequences

- **Bundle size**: Baseline policies are YAML manifests (~10 KB total). Cilium
  images add ~500 MB only if the enhanced profile is selected.
- **Minimum cluster requirements**: Any CNI that supports NetworkPolicy (most do).
  Enhanced profile requires Cilium as the cluster CNI.
- **Bootstrap complexity**: Baseline policies applied via `kubectl apply -f`.
  Cilium detection is a single CRD check. No additional operator installation
  required (Cilium must be pre-installed as the cluster CNI).
- **Customer integration**: Documentation in `docs/NETWORK_REQUIREMENTS.md`
  describes RUNE's network requirements so customers can integrate with their
  existing policy framework.
- **IEC 62443 SR 5.1**: Demonstrable network segmentation via namespace isolation
  and explicit allow-list policies.
- **IEC 62443 SR 5.2**: L7 zone boundary protection available with Cilium enhanced
  layer. Baseline provides L3/L4 minimum.
- **Audit trail**: With Cilium + Hubble, all network flows are logged and
  observable for security audit. Without Cilium, standard K8s audit logging
  captures policy violations.
