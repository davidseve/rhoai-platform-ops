# Workarounds

Active workarounds applied in this project. Each entry documents a known issue and its temporary fix.

## GuideLLM pods OOMKill with default 2Gi memory limit

- **Date**: 2026-05-26
- **Affected version**: RHOAI 3.4 (EvalHub Tech Preview)
- **Bug/Issue**: No upstream issue — EvalHub CRD does not expose a `resources` field for benchmark pod configuration
- **Expected resolution**: EvalHub GA (expected to add runtime resource overrides in the CRD)

### Problem

GuideLLM benchmark pods created by EvalHub crash with `Worker process received error signal` when running the `throughput` benchmark (which internally uses `--profile sweep`). The sweep profile spawns multiple concurrent workers that exceed the default 2Gi memory limit set in the OOTB provider ConfigMap (`evalhub-provider-guidellm`).

The [BENCHMARKS.md](../modules/evaluation/docs/BENCHMARKS.md) documentation already notes that the sweep profile requires 4Gi.

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
   make evalhub-benchmark MODEL_NAME=tinyllama-fast
   ```
3. When EvalHub GA adds a `resources` or `runtimes` field to the CRD, configure it in `modules/evaluation/charts/evaluation/templates/evalhub.yaml` and remove this workaround.
