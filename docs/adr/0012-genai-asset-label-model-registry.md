# ADR-0012: AI Asset Endpoints Discovery — MaaSModelRef vs genai-asset Label

## Status
Accepted

## Context

RHOAI 3.4 has multiple paths for models to appear in the Gen AI Studio
"AI asset endpoints" page and Playground. We investigated which mechanism
is correct for LLMInferenceService models deployed via Helm/ArgoCD.

### Discovery Sources

The dashboard (`rhods-dashboard`) has separate BFF containers that each
contribute models to AI asset endpoints:

| Container | Source | Discovery mechanism |
|-----------|--------|-------------------|
| `gen-ai-ui` | `opendatahub.io/genai-asset: "true"` label | Kubernetes API watch on InferenceService/LLMInferenceService |
| `maas-ui` | `MaaSModelRef` CRs → `maas-api` `/v1/models` | REST query to the MaaS API |
| `gen-ai-ui` | ConfigMap `gen-ai-aa-custom-model-endpoints` | Custom/external endpoints |

The `model-registry-ui` container handles the Models > Registry page separately
and does NOT feed into AI asset endpoints.

### The Duplication Problem

When both `genai-asset: true` label AND `MaaSModelRef` (via `modelRef.enabled: true`)
are active, the Playground "Configure" dialog shows **6 entries** instead of 3 —
one set from `gen-ai-ui` (label) and one set from `maas-ui` (MaaS API).

### Investigation Timeline

1. Without `genai-asset` and without `modelRef`: no models in AI asset endpoints
2. With `genai-asset` only: models appear but only via gen-ai path
3. With `genai-asset` + `modelRef`: **duplicates** in Playground (6 entries)
4. With `modelRef` only (no `genai-asset`): **3 models, no duplicates, correct metadata**
   — models show Use case "LLM", Status "Ready", visible across all namespaces

### Root Cause of "First Time Empty"

On initial bootstrap, all model-related ArgoCD apps were on sync-wave 2 (same as
platform infrastructure). This created a race condition where:
- The `maas-api` might not be ready when `MaaSModelRef` CRs are created
- The dashboard page was visited before models finished deploying

Fix: model apps moved to sync-wave 3, ensuring the MaaS platform (wave 1) and
Model Registry (wave 2) are fully ready before models deploy.

## Options Considered

### Option 1: genai-asset label only
- **Pros:** Simple, documented in blogs and NVIDIA guides
- **Cons:** Bypasses the MaaS platform; models lack MaaS metadata (use case, description);
  conflicts with MaaSModelRef causing duplicates

### Option 2: MaaSModelRef only (no genai-asset label)
- **Pros:** Correct for MaaS deployments; provides rich metadata (use case, description,
  display name, context window); no duplicates; models visible globally across namespaces;
  integrates with MaaS governance (subscriptions, rate limits, auth policies)
- **Cons:** Requires MaaS platform to be running (`maas-api`, `maas-controller`)

### Option 3: Both genai-asset + MaaSModelRef
- **Pros:** Maximum compatibility
- **Cons:** Playground shows duplicate entries (confirmed)

## Decision

Use **Option 2: MaaSModelRef only**.

- Do NOT add `opendatahub.io/genai-asset: "true"` to LLMInferenceService
- Keep `modelRef.enabled: true` — the `MaaSModelRef` CR feeds models into
  AI asset endpoints via `maas-ui` → `maas-api`
- Keep `registry.enabled: true` — the Model Registry is a separate governance
  feature that does NOT cause duplicates
- Sync-wave ordering: platform (wave 1) → model-registry (wave 2) → models (wave 3)

### When genai-asset IS needed

The `genai-asset` label is only needed for:
- Standalone InferenceService deployments (not using MaaS/LLMInferenceService)
- Environments without the MaaS controller

## Consequences

### Positive
- No duplicate models in AI asset endpoints or Playground
- Rich metadata (Use case, Description, Display Name) from MaaSModelRef annotations
- Models visible globally across all namespaces via MaaS API
- Model Registry available for governance (separate, non-conflicting)
- Proper sync-wave ordering prevents race conditions on fresh bootstrap

### Negative
- Depends on MaaS platform being operational (maas-api, maas-controller)
- Less documented than the `genai-asset` approach (most blogs show `genai-asset`)

## Key Technical Details

### Dashboard Architecture
```
rhods-dashboard pod containers:
  rhods-dashboard    — main frontend
  gen-ai-ui          — Gen AI BFF (genai-asset label discovery)
  maas-ui            — MaaS BFF (MaaSModelRef/maas-api discovery)
  model-registry-ui  — Model Registry BFF (separate, no AI asset feed)
  mlflow-ui          — MLflow BFF
  eval-hub-ui        — EvalHub BFF
  automl-ui          — AutoML BFF
  autorag-ui         — AutoRAG BFF
  kube-rbac-proxy    — Auth proxy
```

### MaaSModelRef CR
```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: <model-name>
  annotations:
    opendatahub.io/genai-use-case: chat
    opendatahub.io/context-window: "4096"
    openshift.io/display-name: "Human-readable name"
    openshift.io/description: "Model description"
spec:
  modelRef:
    kind: LLMInferenceService
    name: <model-name>
```

### ArgoCD Sync Wave Ordering
| Wave | Apps |
|------|------|
| 0 | database, maas-operators, observability-operators |
| 1 | maas-platform (creates maas-api, maas-controller), observability |
| 2 | maas-model-registry, evaluation |
| 3 | maas-model, maas-model-fast, maas-model-granite-2b |

## References
- [RHOAI 3.4 Playground docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/experimenting_with_models_in_the_gen_ai_playground/index)
- [RHOAI 3.4 Known Issues](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/release_notes/known-issues_relnotes)
- [ODH Dashboard repo](https://github.com/opendatahub-io/odh-dashboard) — packages/gen-ai, packages/maas
- [ODH MaaS repo](https://github.com/opendatahub-io/models-as-a-service)
- [ADR-0010: Model Registry PostgreSQL](docs/adr/0010-model-registry-postgresql.md)
