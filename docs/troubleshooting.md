# Troubleshooting

Common issues and solutions for RUNE air-gapped deployments.

## Bundle Verification Failures

### SHA256 checksum verification failed

**Symptom**: Bootstrap exits with code 3 and the message
`SHA256 checksum verification FAILED`.

**Cause**: The bundle was corrupted during transfer, or the file was modified
after creation.

**Solution**:
1. Re-transfer the bundle from the source.
2. Verify the outer tarball checksum before running bootstrap:
   ```bash
   sha256sum rune-bundle-v0.0.0a2.tar.gz
   ```
3. Compare against the checksum provided in the release notes.
4. If checksums match but internal verification still fails, the bundle may
   have been built incorrectly. Rebuild the bundle on the connected host.

### Cosign signature verification failed

**Symptom**: Image signature verification reports `FAILED` for one or more
images.

**Cause**: The images were not signed during bundle creation, or the public
key does not match the signing key.

**Solution**:
1. Ensure the bundle was built with `--sign` and a valid cosign key.
2. Verify the public key (`cosign.pub`) in the bundle matches the key used
   during signing.
3. If signature verification is not required in your environment, use
   `--skip-verify` (not recommended for production).

## Registry Not Starting

### Zot pod stuck in CrashLoopBackOff

**Symptom**: `kubectl get pods -n rune-registry` shows the zot pod in
`CrashLoopBackOff`.

**Causes and solutions**:

1. **Resource limits too low**: Check if the pod is being OOMKilled.
   ```bash
   kubectl describe pod -n rune-registry -l app.kubernetes.io/name=zot
   ```
   Look for `OOMKilled` in the `Last State` section. Increase memory limits
   in your custom values file.

2. **PSA violation**: The zot container must run as non-root with a read-only
   root filesystem. Check events:
   ```bash
   kubectl get events -n rune-registry --sort-by='.lastTimestamp'
   ```

3. **Storage issues**: The `emptyDir` volume has a 10Gi size limit. If the
   registry data exceeds this, the pod will be evicted. For production, use a
   PersistentVolumeClaim.

### Zot deployment times out

**Symptom**: Bootstrap hangs at "Waiting for zot registry to be ready" and
eventually times out after 120 seconds.

**Solution**:
1. Check if the zot image is available on the node:
   ```bash
   kubectl describe pod -n rune-registry -l app.kubernetes.io/name=zot
   ```
   Look for `ErrImagePull` or `ImagePullBackOff` events.
2. The zot container image must be pre-loaded onto the node before bootstrap.
   This is typically done by importing the image from the bundle into the
   node's container runtime:
   ```bash
   ctr -n k8s.io images import zot-linux-amd64.tar
   ```

## Image Pull Errors

### ErrImagePull / ImagePullBackOff for RUNE images

**Symptom**: RUNE component pods fail to start with `ErrImagePull` or
`ImagePullBackOff`.

**Causes and solutions**:

1. **containerd not configured for in-cluster registry**: Nodes must be
   configured to resolve images from `rune-registry.rune-registry.svc:5000`.
   See [Prerequisites - Containerd Mirror Configuration](prerequisites.md#containerd-mirror-configuration).

2. **Images not loaded into registry**: Verify images are available:
   ```bash
   kubectl port-forward -n rune-registry svc/zot 5000:5000 &
   curl http://localhost:5000/v2/_catalog
   ```
   If the catalog is empty, images were not loaded. Check if `crane` was
   available during bootstrap. If not, load images manually:
   ```bash
   crane push <oci-layout-dir> localhost:5000/<image-name>:latest
   ```

3. **DNS resolution failure**: The image reference
   `rune-registry.rune-registry.svc:5000/<image>` requires working CoreDNS.
   Verify:
   ```bash
   kubectl run dns-test --rm -it --image=busybox -- nslookup \
     zot.rune-registry.svc.cluster.local
   ```

4. **Network policy blocking pulls**: Ensure the egress-to-registry
   NetworkPolicy is applied:
   ```bash
   kubectl get networkpolicy -n rune allow-egress-to-registry
   ```

### crane not available during bootstrap

**Symptom**: Bootstrap logs show `crane not available for image loading`.

**Cause**: The `crane` binary is not installed on the target host.

**Solution**: Either install `crane` on the target host, or load images
manually. You can include `crane` in the bundle by placing it under
`<bundle>/tools/crane`.

## TLS Certificate Issues

### x509: certificate signed by unknown authority

**Symptom**: Image pulls or API calls fail with TLS certificate errors.

**Cause**: Services are configured with TLS using a private CA, but the CA
certificate is not trusted by clients.

**Solution**:

1. **For containerd (image pulls)**: Configure the CA certificate in the
   containerd hosts.d configuration:
   ```toml
   [host."https://rune-registry.rune-registry.svc:5000"]
     capabilities = ["pull", "resolve"]
     ca = "/path/to/ca.crt"
   ```
   Restart containerd on each node.

2. **For in-cluster services**: Mount the CA certificate as a ConfigMap or
   Secret and configure each service to trust it.

3. **For kubectl/helm**: Set the `--certificate-authority` flag or add the CA
   to the system trust store:
   ```bash
   sudo cp ca.crt /usr/local/share/ca-certificates/rune-ca.crt
   sudo update-ca-certificates
   ```

### TLS handshake timeout

**Symptom**: Connections to the registry or services time out during TLS
handshake.

**Cause**: Port mismatch between HTTP and HTTPS configuration, or the service
is not listening on the expected port.

**Solution**: Verify the service is configured consistently. If `global.tls.enabled`
is `true`, all service URLs must use HTTPS. Check the Zot config, Helm values,
and containerd configuration for consistency.

## Pod Scheduling Failures

### Pods stuck in Pending

**Symptom**: `kubectl get pods` shows pods in `Pending` state.

**Causes and solutions**:

1. **ResourceQuota exceeded**: Check quota usage:
   ```bash
   kubectl describe resourcequota -n rune
   ```
   If the quota is exhausted, either increase the quota or reduce resource
   requests in your values file. You can also skip quotas with
   `--no-resource-quotas`.

2. **Insufficient node resources**: Check available resources:
   ```bash
   kubectl describe nodes | grep -A 5 "Allocated resources"
   ```

3. **LimitRange defaults too high**: The default LimitRange sets container
   defaults of 500m CPU and 512Mi memory. If nodes are small, these defaults
   may prevent scheduling. Override with a custom values file.

4. **PVC not bound**: If a pod requires a PVC, check if the StorageClass and
   provisioner are available:
   ```bash
   kubectl get pvc -A
   kubectl get storageclass
   ```

### Pod security admission rejection

**Symptom**: Pods fail to create with a message about violating
PodSecurity policy.

**Cause**: The pod spec does not meet the `restricted` PSA profile.

**Solution**: All RUNE containers are designed to comply with the `restricted`
profile. If you see this error with a custom configuration:
- Ensure `securityContext.runAsNonRoot: true`
- Ensure `securityContext.allowPrivilegeEscalation: false`
- Ensure `securityContext.capabilities.drop: ["ALL"]`
- Ensure `securityContext.seccompProfile.type: RuntimeDefault`
- Ensure `securityContext.readOnlyRootFilesystem: true`

## Network Policy Blocking Traffic

### Services cannot communicate

**Symptom**: RUNE components fail to connect to each other (connection
refused, timeout).

**Cause**: NetworkPolicies enforce default-deny in all RUNE namespaces.
Allow rules may be missing or misconfigured.

**Diagnostic steps**:

1. List active policies:
   ```bash
   kubectl get networkpolicy -A -l app.kubernetes.io/part-of=rune
   ```

2. Verify the expected allow rules are present:
   - `allow-ui-to-api` in `rune` namespace
   - `allow-operator-to-api` in `rune` namespace
   - `allow-operator-egress-to-api` in `rune-system` namespace
   - `allow-egress-to-registry` in `rune` and `rune-system` namespaces
   - `allow-dns` in all RUNE namespaces

3. Check if the CNI plugin is correctly enforcing policies:
   ```bash
   kubectl logs -n kube-system -l k8s-app=calico-node --tail=50
   # or for Cilium:
   kubectl logs -n kube-system -l k8s-app=cilium --tail=50
   ```

**Workaround**: To temporarily disable network policies for debugging:
```bash
kubectl delete networkpolicy --all -n rune
kubectl delete networkpolicy --all -n rune-system
kubectl delete networkpolicy --all -n rune-registry
```

Re-apply them after debugging:
```bash
kubectl apply -f manifests/network-policies/vanilla/
```

### DNS resolution fails due to egress policy

**Symptom**: Pods cannot resolve service names. `nslookup` fails from within
pods.

**Cause**: The `allow-dns` NetworkPolicy may be missing.

**Solution**: Apply the DNS allow policy:
```bash
kubectl apply -f manifests/network-policies/vanilla/allow-dns.yaml
```

## Upgrade Failures and Recovery

### Helm upgrade fails with "another operation in progress"

**Symptom**: `helm upgrade` reports that another operation is in progress for
the release.

**Solution**:
```bash
# Check release status
helm status rune -n rune

# If stuck in a pending state, rollback first
helm rollback rune 0 -n rune
```

### Upgrade leaves pods in mixed versions

**Symptom**: After upgrade, some pods run the old version and some the new.

**Cause**: The rolling update did not complete, possibly due to resource
constraints or failed readiness probes.

**Solution**:
1. Check rollout status:
   ```bash
   kubectl rollout status deployment/rune-api -n rune
   ```
2. If stuck, describe the deployment for events:
   ```bash
   kubectl describe deployment/rune-api -n rune
   ```
3. Force a restart if needed:
   ```bash
   kubectl rollout restart deployment/rune-api -n rune
   ```

### Rolling back after a failed upgrade

If an upgrade fails and the system is in a broken state:

1. Identify the last working revision:
   ```bash
   helm history rune -n rune
   ```
2. Rollback:
   ```bash
   helm rollback rune <REVISION> -n rune
   ```
3. If the old images are no longer in the registry, re-deploy the previous
   bundle with `--registry-only` to reload images, then rollback:
   ```bash
   ./scripts/bootstrap.sh \
     --bundle /path/to/previous-bundle.tar.gz \
     --registry-only

   helm rollback rune <REVISION> -n rune
   helm rollback rune-operator <REVISION> -n rune-system
   helm rollback rune-ui <REVISION> -n rune
   ```

## Collecting Diagnostic Information

When reporting issues, collect the following:

```bash
# Cluster info
kubectl cluster-info
kubectl version

# Pod status across all RUNE namespaces
kubectl get pods -A -l app.kubernetes.io/part-of=rune -o wide

# Events (sorted by time)
kubectl get events -n rune --sort-by='.lastTimestamp'
kubectl get events -n rune-system --sort-by='.lastTimestamp'
kubectl get events -n rune-registry --sort-by='.lastTimestamp'

# Resource usage
kubectl top pods -A -l app.kubernetes.io/part-of=rune
kubectl describe resourcequota -A

# Bootstrap log
cat bootstrap-*.log
```
