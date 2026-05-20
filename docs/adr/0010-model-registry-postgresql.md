# ADR-0010: Model Registry with PostgreSQL Backend

## Status

Accepted

## Context

We need a model governance catalog to:
1. Make deployed models visible in the RHOAI Dashboard UI
2. Link serving models to MLflow evaluation experiments for traceability
3. Maintain a single source of truth for model metadata (name, URI, tier, use case)

RHOAI includes two separate registry systems:
- **RHOAI Model Registry** (Kubeflow Model Registry / MLMD) — designed for serving model governance, supports declarative registration via ConfigMap catalog
- **MLflow Model Registry** — built into MLflow Tracking Server, designed for models created from training runs (`mlflow.log_model()`)

Our models are pre-trained serving models (vLLM), not products of training pipelines. RHOAI Model Registry is the right fit.

## Options Considered

### Option 1: MySQL backend (Red Hat documented default)

- Pros: officially documented in Red Hat examples and [Quick Course](https://github.com/RedHatQuickCourses/rhoai3-registry); lower risk
- Cons: requires deploying a new MySQL instance; all other services (MaaS API, MLflow, EvalHub) use PostgreSQL

### Option 2: PostgreSQL — reuse shared maas-db (chosen)

- Pros: no new database instance; operational simplicity; MLMD tables don't collide with MLflow/MaaS tables; supported since Kubeflow Model Registry 1.11 / operator v0.3.x via `spec.postgres` in CRD
- Cons: PostgreSQL not in Red Hat's official examples (only in upstream CRD and operator); shared DB is a single point of failure; `sslMode: disable` (consistent with all other consumers — TLS is a cross-cutting future task)

### Option 3: PostgreSQL — dedicated database

- Pros: isolation from other consumers
- Cons: extra database to manage; the `maas` database has no schema collisions (MLMD uses `Type`, `Artifact`, `Context`, `Event` tables that are unique)

## Decision

Use **Option 2**: PostgreSQL reusing the shared `maas-db` instance with `skipDBCreation: true`.

The Model Registry is deployed as a separate Helm chart (`modules/maas/charts/model-registry/`) in the `rhoai-model-registries` namespace, with its own ArgoCD Application at sync-wave 2 (after DSC enables the modelregistry component in wave 1).

Model registration is declarative via ConfigMap catalog entries generated from the `maas-model` chart — no duplication of model metadata, no post-install Jobs or scripts.

## Consequences

- **Positive**: no new infrastructure; consistent with existing PostgreSQL backend; GitOps-native (all resources managed by Helm/ArgoCD); model metadata lives with model definition (DRY)
- **Positive**: traceability via `customProperties.mlflow_experiment` linking RHOAI catalog to MLflow experiment names
- **Negative**: if PostgreSQL is not supported in a specific RHOAI version, fallback to `spec.postgres.generateDeployment: true` (operator auto-provisions) or MySQL
- **Negative**: shared DB failure affects all consumers (low risk — Model Registry has low write volume, metadata only)

## References

- [Model Registry Operator (upstream)](https://github.com/opendatahub-io/model-registry-operator) — v0.3.9, PostgreSQL + MySQL support
- [CRD spec.postgres](https://github.com/opendatahub-io/model-registry-operator/blob/main/config/crd/bases/modelregistry.opendatahub.io_modelregistries.yaml) — `v1beta1` storage version
- [Kubeflow Model Registry](https://www.kubeflow.org/docs/components/model-registry/) — PostgreSQL since Kubeflow 1.11
- [Red Hat Quick Course: rhoai3-registry](https://github.com/RedHatQuickCourses/rhoai3-registry) — MySQL example
