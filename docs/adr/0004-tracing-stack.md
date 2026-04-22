# ADR-0004: Tracing Stack (Red Hat OTel + Tempo)

## Status

Accepted

## Context

Phase 2 of the roadmap adds distributed tracing to the observability module. We need to choose a tracing backend and collector that align with the project's Red Hat product priority (ADR-0002) while integrating with the existing Grafana + Prometheus stack.

Key requirements:
- OTLP-native ingestion (vLLM and future components emit OTLP traces)
- Grafana integration (trace exploration via existing Grafana instance)
- Derive RED metrics from traces (span-based latency, error rate, request rate)
- Operator-managed CRDs for GitOps compatibility

## Options Considered

### Option 1: Red Hat build of OpenTelemetry + Red Hat build of Tempo

- **Pros:** Red Hat-supported operators, OTLP-native, Tempo has native Grafana datasource, OTel Collector supports `spanmetrics` connector for derived metrics, both available from `redhat-operators` catalog
- **Cons:** TempoMonolithic is suitable for single-tenant dev/test; production multi-tenant requires TempoStack with S3-compatible storage

### Option 2: Jaeger (via Red Hat OpenShift distributed tracing)

- **Pros:** Mature, widely used, Red Hat-supported
- **Cons:** Jaeger is being deprecated in favor of Tempo in the OpenShift ecosystem, requires Elasticsearch or Cassandra backend, does not derive metrics from traces natively

### Option 3: No tracing (metrics only)

- **Pros:** No additional components
- **Cons:** Cannot trace individual requests through the gateway -> model stack, blind to per-request latency breakdown

## Decision

Use **Option 1: Red Hat build of OpenTelemetry + Red Hat build of Tempo**.

- **Tempo Operator** deploys a `TempoMonolithic` CR with memory backend (suitable for dev/test, traces lost on restart). Upgrade path to PV or S3 backend is documented for production.
- **OpenTelemetry Operator** deploys an `OpenTelemetryCollector` CR with:
  - OTLP gRPC + HTTP receivers
  - `spanmetrics` connector (derives latency histograms from traces)
  - `otlp/tempo` exporter (forwards traces to Tempo)
  - `prometheus` exporter (exposes span-derived metrics)
- Both operators deploy in their own namespaces (`openshift-tempo-operator`, `openshift-opentelemetry-operator`); the Collector and Tempo instances deploy in the shared `observability` namespace.

### Deferred decisions

- **Gateway/Envoy tracing**: Requires Istio `Telemetry` CR to configure Envoy -> OTel Collector. Deferred because Service Mesh 3 (Sail Operator) interaction with `serviceMesh.managementState: Removed` in DSCI needs investigation.
- **Persistent Tempo storage**: Memory backend is sufficient for dev/test. Production requires S3-compatible storage (MinIO or ODF).
- **Token-level vLLM tracing**: Requires a newer vLLM image with OTEL Python packages. Current CPU image lacks these.

## Consequences

### Positive

- Full OTLP trace pipeline from model pods to Grafana
- Span-derived RED metrics complement existing vLLM-native metrics
- GitOps-managed via CRDs (TempoMonolithic, OpenTelemetryCollector)
- Aligns with Red Hat product direction (Tempo replacing Jaeger)
- Tracing is opt-in (`tracing.enabled: false`) -- zero impact on existing deployments

### Negative

- Memory-backed Tempo loses traces on pod restart (acceptable for dev/test)
- Gateway-level tracing not yet available (traces start at vLLM layer)
- Additional operator footprint (2 more operators + 2 more pods)

### Neutral

- vLLM tracing depends on OTEL support in the container image; env vars are set but may be no-ops until a compatible image is deployed
- ServiceMonitor for OTel Collector enables monitoring of the tracing pipeline itself

## References

- [Red Hat build of OpenTelemetry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/red_hat_build_of_opentelemetry/index)
- [Red Hat build of Tempo](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/red_hat_build_of_tempo/index)
- [ADR-0002: Red Hat Product Priority](0002-red-hat-priority.md)
- [ADR-0003: Grafana Operator](0003-grafana-operator.md)
