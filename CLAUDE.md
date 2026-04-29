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
```

## Rules

- Red Hat products first, community only as fallback
- Helm-first workflow: `helm template` → `helm install` → ArgoCD
- Every non-obvious decision gets an ADR in `docs/adr/`
- Tests must be idempotent and runnable via `make test-<module>`
- Update `AGENTS.md` and `CLAUDE.md` when adding modules or skills
- Update `scripts/cluster-cleanup.sh` when adding modules
