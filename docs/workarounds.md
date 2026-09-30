# Workarounds

Active workarounds applied in this project. Each entry documents a known issue and its temporary fix.

## GuideLLM pods OOMKill with default 2Gi memory limit

- **Date**: 2026-05-26
- **Affected version**: RHOAI 3.4 (EvalHub Tech Preview)
- **Bug/Issue**: No upstream issue — EvalHub CRD does not expose a `resources` field for benchmark pod configuration
- **Expected resolution**: EvalHub GA (expected to add runtime resource overrides in the CRD)

### Problem

GuideLLM benchmark pods created by EvalHub crash with `Worker process received error signal` when running the `throughput` benchmark (which internally uses `--profile sweep`). The sweep profile spawns multiple concurrent workers that exceed the default 2Gi memory limit set in the OOTB provider ConfigMap (`evalhub-provider-guidellm`).

The [BENCHMARKS.md](BENCHMARKS.md) documentation notes that the sweep profile requires 4Gi.

### Workaround

Patch the GuideLLM provider ConfigMap in the `evaluation` namespace to increase memory from 2Gi to 4Gi:

```bash
# Scale down the TrustyAI operator to prevent reconciliation
oc scale deployment -n redhat-ods-applications \
  trustyai-service-operator-controller-manager --replicas=0

# Wait for operator pod to terminate
sleep 10

# Patch the provider ConfigMap
YAML_CONTENT=$(oc get configmap -n evaluation evalhub-provider-guidellm \
  -o jsonpath='{.data.guidellm\.yaml}')
NEW_YAML=$(echo "$YAML_CONTENT" \
  | sed 's/memory_limit: 2Gi/memory_limit: 4Gi/' \
  | sed 's/memory_request: 128Mi/memory_request: 256Mi/')
ESCAPED=$(echo "$NEW_YAML" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
oc patch configmap -n evaluation evalhub-provider-guidellm \
  --type=merge -p="{\"data\":{\"guidellm.yaml\":$ESCAPED}}"

# Scale operator back up
oc scale deployment -n redhat-ods-applications \
  trustyai-service-operator-controller-manager --replicas=1
```

**Notes:**
- The source ConfigMap in `redhat-ods-applications` (`trustyai-service-operator-evalhub-provider-guidellm`) is owned by the RHOAI operator (`TrustyAI` component CR) and cannot be patched — it reconciles immediately.
- The copy in `evaluation` is owned by the TrustyAI operator but does NOT get reconciled on operator restart (only on EvalHub CR creation).
- If the evaluation module is reinstalled or the EvalHub CR is recreated, the patch will be lost and must be reapplied.

### How to verify the fix

1. Check that the ConfigMap has 4Gi:
   ```bash
   oc get configmap -n evaluation evalhub-provider-guidellm \
     -o jsonpath='{.data.guidellm\.yaml}' | grep memory_limit
   ```
2. Run a GuideLLM benchmark and verify it completes:
   ```bash
   make evalhub-benchmark MODEL_NAME=granite-2b
   ```
3. When EvalHub GA adds a `resources` or `runtimes` field to the CRD, configure it in `modules/evaluation/charts/evaluation/templates/evalhub.yaml` and remove this workaround.

## COO NetworkPolicy blocks Thanos gRPC (port 10901)

- **Date**: 2026-07-09 (re-validated 2026-09-30 on COO 1.5.2)
- **Affected version**: COO 1.5.x
- **Bug/Issue**: COO creates `data-science-prometheus-instance-ingress` NetworkPolicy in `redhat-ods-monitoring` but omits port 10901 (gRPC) — Thanos Querier cannot reach Prometheus sidecar
- **Expected resolution**: COO 1.6+ or RHOAI 3.5

### Workaround

Additional NetworkPolicy `thanos-querier-to-sidecar` in `modules/observability/charts/operators/templates/coo-workarounds.yaml` allows port 10901 from Thanos Querier to Prometheus pods.

### How to remove

When COO includes port 10901 in its auto-created NetworkPolicy, delete the workaround template and verify Thanos shows metrics.

## COO Perses Operator NetworkPolicy wrong namespace

- **Date**: 2026-07-09 (re-validated 2026-09-30 on COO 1.5.2)
- **Affected version**: COO 1.5.x
- **Bug/Issue**: COO creates `perses-operator-access` NetworkPolicy pointing to namespace `openshift-cluster-observability-operator`, but the Perses Operator runs in `openshift-operators`
- **Expected resolution**: COO 1.6+ or RHOAI 3.5

### Workaround

Additional NetworkPolicy `perses-operator-access-fix` in `modules/observability/charts/operators/templates/coo-workarounds.yaml` allows traffic from `openshift-operators`.

### How to remove

When COO creates the NetworkPolicy with the correct namespace, delete the workaround template and verify Perses dashboards reconcile.

## COO Perses CA volume not mounted

- **Date**: 2026-07-09 (re-validated 2026-09-30 on COO 1.5.2)
- **Affected version**: COO 1.5.x
- **Bug/Issue**: `PersesGlobalDatasource` docs specify `certPath: /ca/service-ca.crt` but COO does not mount a CA volume at `/ca/` — only the projected SA volume at `/var/run/secrets/kubernetes.io/serviceaccount/` is available
- **Expected resolution**: COO 1.6+ or RHOAI 3.5

### Workaround

Use `certPath: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt` (the SA projected volume includes the service-ca cert on OpenShift).

### How to remove

When COO mounts a CA volume at `/ca/`, revert to the documented `certPath: /ca/service-ca.crt`.

## COO Perses datasource missing bearer token (kubernetesAuth bug)

- **Date**: 2026-07-09 (re-validated 2026-09-30 on COO 1.5.2)
- **Affected version**: COO 1.5.x (Cluster Observability Operator)
- **Bug/Issue**: `PersesGlobalDatasource` CRD `client.kubernetesAuth.enable: true` has no effect — operator creates Perses secret with only `tlsConfig`, no `authorization` field
- **Expected resolution**: COO 1.6+ or RHOAI 3.5 (when operator implements `kubernetesAuth` or adds `credentialsFile` to CRD client spec)

### Problem

The Perses dashboards in the OpenShift Console (via COO UIPlugin `monitoring`) need authenticated access to Thanos Querier. The `PersesGlobalDatasource` CRD has `client.kubernetesAuth.enable` but the operator ignores it — the generated Perses secret only contains TLS config, not an `authorization` field. The operator also **overwrites** any manual patches to the secret on every reconciliation cycle.

Without the bearer token, Perses cannot query Thanos and dashboards show no data.

### Workaround

An ArgoCD PostSync Job (`perses-auth-fix.yaml`) patches the Perses global secret after each sync to inject `authorization.credentialsFile` pointing to the ServiceAccount token:

**File**: `modules/maas/charts/maas-platform/templates/monitoring/perses-auth-fix.yaml`

The Job:
1. Reads the current Perses global datasource secret
2. Patches it to add `authorization.credentialsFile: /var/run/secrets/kubernetes.io/serviceaccount/token`
3. Runs as PostSync so it re-applies after every ArgoCD sync (because the operator overwrites the secret)

### How to verify the fix

1. Check the Perses secret has the authorization field:
   ```bash
   oc get secret -n redhat-ods-monitoring -l perses.dev/datasource=true \
     -o jsonpath='{.items[0].data}' | base64 -d
   ```
2. Open the RHOAI Dashboard → Observe & Monitor → Usage tab — data should appear
3. Check PostSync Job logs:
   ```bash
   oc logs job/perses-auth-fix -n redhat-ods-monitoring
   ```

### How to remove

When COO implements `kubernetesAuth` properly:
1. Delete `modules/maas/charts/maas-platform/templates/monitoring/perses-auth-fix.yaml`
2. Remove the `coo.workarounds.persesAuth` value from `values.yaml` (if gated)
3. Verify Perses dashboards still show data without the PostSync Job
4. Update [ADR-0013](adr/0013-coo-observability-migration.md) Bug 4 as resolved
