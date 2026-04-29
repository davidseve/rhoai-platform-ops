---
description: "Helm chart conventions for modules and ArgoCD applications."
globs:
  - "modules/**/charts/**/*.yaml"
  - "modules/**/charts/**/*.tpl"
  - "argocd/**/*.yaml"
---

# Helm Chart Conventions

## Sync Options

Resources that depend on CRDs (custom resources) must include:
```yaml
annotations:
  argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

## Global Values

Use `{{ .Values.global.name }}` and `{{ .Values.global.namespace }}` for resource naming and placement.

## Conditional Resources

Gate optional resources with:
```yaml
{{- if .Values.<feature>.enabled }}
```

## Values Documentation

Every chart must have a `values.yaml` with:
- Comments explaining each top-level key
- Sensible defaults that work for local/dev testing
- No hardcoded cluster-specific values (use CHANGE_ME placeholders)

## Resource Policy

Resources that should survive `helm uninstall` (e.g., OpenShift Groups with manual user memberships):
```yaml
annotations:
  helm.sh/resource-policy: keep
```

## ArgoCD Application Templates

- Use `{{ .Values.repoURL }}` and `{{ .Values.targetRevision }}` instead of hardcoded repo URLs
- Wrap in module enable guard: `{{- if .Values.modules.<name>.enabled }}`
- Set appropriate `sync-wave` annotations for dependency ordering:
  - Wave 0: Operators
  - Wave 1: Platform configuration
  - Wave 2: Workloads (models, services)

## Sync Policy

Standard sync policy for all applications:
```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - SkipDryRunOnMissingResource=true
```

Only add `RespectIgnoreDifferences=true` and `ignoreDifferences` when a
specific resource causes a persistent sync-loop (e.g. CRD version conversion,
operator-injected fields). Current known cases:
- `DSCInitialization /spec` (v1/v2 CRD conversion)
- `Grafana /spec/version` (operator injects image digest)
