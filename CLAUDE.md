# RHOAI Platform Operations

@AGENTS.md

## Commands

Run `make help` for the full list. Key targets:

```bash
make deploy-all           # Deploy observability + MaaS
make test-all             # Run all module tests
make undeploy-all         # Undeploy everything
make cluster-cleanup      # Remove ALL resources from cluster
make deploy-argocd        # Apply ArgoCD app-of-apps
make wait-healthy         # Wait for ArgoCD sync + pods Ready
make bootstrap-argocd     # deploy + wait + test-all (full pipeline)
make lint                 # Helm lint all charts
make template             # Helm template dry-run
make deploy-database      # Deploy shared PostgreSQL database
make undeploy-database    # Undeploy database
make deploy-evaluation    # Deploy EvalHub + MLflow + benchmarks infra
make evalhub-eval         # Quality eval via EvalHub API (EVALHUB_BENCHMARK=arc_easy, MODEL_URL=url)
make evalhub-benchmark    # Performance benchmark (GuideLLM throughput, max-seconds=30)
make evalhub-smoke        # Smoke test: lm-eval limit=1, validates full pipeline
make evalhub-security     # Security scan via Garak (GPU only — too slow on CPU)
make evalhub-status       # Check job status (JOB_ID=uuid)
make evalhub-jobs         # List all evaluation jobs
make evalhub-providers    # List available providers and benchmarks
make evalhub-collections  # List benchmark collections
make undeploy-evaluation  # Undeploy evaluation
make deploy-model-registry   # Deploy Model Registry + catalog
make undeploy-model-registry # Undeploy Model Registry
```

## Rules

- Red Hat products first, community only as fallback
- Helm-first workflow: `helm template` → `helm install` → ArgoCD
- Every non-obvious decision gets an ADR in `docs/adr/`
- Tests must be idempotent and runnable via `make test-<module>`
- Update `AGENTS.md` and `CLAUDE.md` when adding modules or skills
- Update `scripts/cluster-cleanup.sh` when adding modules
