# ADR-0002: Red Hat Product Priority

## Status

Accepted

## Context

Building on OpenShift, we have access to both Red Hat supported products and upstream community projects. For each capability (monitoring, tracing, model serving, etc.) we need to decide which tooling to use. Key considerations:

1. **Support**: Red Hat products come with enterprise support and security patches
2. **Integration**: Red Hat products are tested together on OpenShift
3. **Documentation**: Official Red Hat docs cover OpenShift-specific configuration
4. **Lifecycle**: Red Hat aligns product versions with OpenShift releases
5. **Availability**: Some capabilities may not yet have a Red Hat equivalent

## Options Considered

### Option 1: Community-first
- **Pros:** Latest features, larger ecosystem, more examples online
- **Cons:** No enterprise support, integration issues, version compatibility not guaranteed

### Option 2: Red Hat-first, community as fallback
- **Pros:** Enterprise support, tested integration, aligned lifecycle. Community fills gaps.
- **Cons:** May lag behind upstream features, fewer community examples

### Option 3: Red Hat-only
- **Pros:** Full support coverage
- **Cons:** Some capabilities simply don't have Red Hat equivalents yet (e.g., MLflow, inference-perf)

## Decision

Use **Option 2: Red Hat-first, community as fallback**.

Specific product mapping:

| Capability | Red Hat Product | Fallback |
|------------|----------------|----------|
| Model serving | RHOAI (LLMInferenceService) | -- |
| API governance | Red Hat Connectivity Link (Kuadrant) | -- |
| Monitoring | OpenShift User Workload Monitoring | -- |
| Dashboards | Grafana Operator (community, deployed on OpenShift) | -- |
| Tracing (collector) | Red Hat build of OpenTelemetry | -- |
| Tracing (storage) | Red Hat build of Tempo | -- |
| Load testing | -- | kubernetes-sigs/inference-perf |
| Experiment tracking | -- | MLflow (evaluate RHOAI MLflow Operator when available) |

## Consequences

### Positive
- Enterprise support for core infrastructure (monitoring, tracing, model serving)
- Consistent documentation referencing Red Hat official docs
- Version compatibility assured for OpenShift + RHOAI upgrades

### Negative
- Must track when Red Hat equivalents become available for community tools
- MLflow and inference-perf have no Red Hat support (acceptable for non-critical tooling)

### Neutral
- ADRs will be created when switching from community to Red Hat products

## References

- [RHOAI 3.3 Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/)
- [RHOAI 3.3 Managing Observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_openshift_ai/managing-observability_managing-rhoai)
- [Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.3)
- [Red Hat build of OpenTelemetry](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/)
