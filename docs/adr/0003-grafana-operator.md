# ADR-0003: Grafana Operator for Dashboards

## Status

Accepted

## Context

We need a dashboard solution for the observability module. OpenShift provides two options:

1. **Grafana Operator** (community, from `community-operators` catalog) -- mature, widely adopted, full Grafana feature set, CRD-based dashboard management
2. **Cluster Observability Operator (COO) with Perses** -- Red Hat-supported, but Perses UI is Tech Preview as of OpenShift 4.17, limited dashboard capabilities, no CRD-based dashboard management yet

Per ADR-0002, we prefer Red Hat products. However, Perses (via COO) is not production-ready for our use case.

## Options Considered

### Option 1: Grafana Operator (community)
- **Pros:** Mature CRD API (`GrafanaDashboard`, `GrafanaDatasource`), rich plugin ecosystem, proven OAuth proxy pattern on OpenShift, existing reference implementation in `llama-stack-example`
- **Cons:** Community operator (no Red Hat support), requires `community-operators` catalog

### Option 2: COO with Perses (Red Hat)
- **Pros:** Red Hat-supported, integrated with OpenShift monitoring stack
- **Cons:** Perses is Tech Preview, limited dashboard types, no equivalent to `GrafanaDashboard` CRD for declarative management, not suitable for production dashboards yet

### Option 3: No dashboards (Prometheus UI only)
- **Pros:** Zero additional components
- **Cons:** Poor user experience, no persistent dashboard definitions, no team-friendly visualization

## Decision

Use **Option 1: Grafana Operator** as an interim solution.

The operator deploys in `openshift-operators` (global scope), the Grafana instance in a dedicated `observability` namespace with OpenShift OAuth proxy for authentication. Dashboards are managed declaratively via `GrafanaDashboard` CRs.

## Migration Path

When COO Perses reaches GA with CRD-based dashboard management:
1. Create equivalent Perses dashboard definitions
2. Add COO Subscription to the operators chart
3. Migrate datasource configuration
4. Remove Grafana Operator dependency
5. Update this ADR status to "Superseded by ADR-NNNN"

## Consequences

### Positive
- Full-featured dashboards available now
- Declarative dashboard management via GitOps
- Proven OAuth proxy pattern for secure access
- Reference implementation available in `llama-stack-example`

### Negative
- Community operator without Red Hat enterprise support
- Must monitor COO Perses GA readiness and plan migration

### Neutral
- `grafana.enabled` flag (default `false`) allows clean opt-in/opt-out
- Monitoring (PodMonitor, PrometheusRule) is independent of Grafana -- works with or without dashboards

## References

- [Grafana Operator](https://github.com/grafana/grafana-operator)
- [Cluster Observability Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/cluster-observability-operator)
- [ADR-0002: Red Hat Product Priority](0002-red-hat-priority.md)
