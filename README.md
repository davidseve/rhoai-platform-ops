# RHOAI Platform Operations

Modular GitOps repository for deploying and operating Red Hat OpenShift AI (RHOAI) infrastructure -- model serving, API governance, observability, benchmarks, and evaluation.

## Prerequisites

- OpenShift 4.20+
- Cluster admin access
- `oc` CLI installed and logged in
- OpenShift GitOps (ArgoCD) installed
- Helm 3.x

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/davidseve/rhoai-platform-ops.git
cd rhoai-platform-ops
```

### 2. Deploy with Helm (for testing)

```bash
make deploy-observability   # Grafana, OTel Collector, Tempo
make deploy-maas            # RHOAI, Kuadrant, model serving
```

### 3. Run tests

```bash
make test-all               # observability + MaaS tests
```

### 4. Deploy with ArgoCD (for stable)

Edit `argocd/app-of-apps.yaml` and set your cluster domain, then:

```bash
make deploy-argocd
```

## Modules


| Module            | Status  | Description                                                        |
| ----------------- | ------- | ------------------------------------------------------------------ |
| **maas**          | Ready   | Models-as-a-Service: RHOAI + Kuadrant API governance               |
| **observability** | Ready   | Grafana dashboards, vLLM metrics, alerts, distributed tracing      |
| **benchmarks**    | Planned | Load testing with inference-perf                                   |
| **evaluation**    | Planned | MLflow tracking and model evaluation                               |


Enable/disable modules in `argocd/apps/values.yaml` under `modules:`.

## Documentation


| Topic                         | Link                                                                                       |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| Project structure and modules | [docs/PROJECT-STRUCTURE.md](docs/PROJECT-STRUCTURE.md)                                     |
| Roadmap and master plan       | [docs/ROADMAP.md](docs/ROADMAP.md)                                                         |
| Architecture Decision Records | [docs/adr/](docs/adr/)                                                                     |
| MaaS architecture             | [modules/maas/docs/ARCHITECTURE.md](modules/maas/docs/ARCHITECTURE.md)                     |
| MaaS gateway and routing      | [modules/maas/docs/GATEWAY-AND-ROUTE.md](modules/maas/docs/GATEWAY-AND-ROUTE.md)           |
| MaaS in-cluster access        | [modules/maas/docs/IN-CLUSTER-ACCESS.md](modules/maas/docs/IN-CLUSTER-ACCESS.md)           |
| MaaS troubleshooting          | [modules/maas/docs/TROUBLESHOOTING.md](modules/maas/docs/TROUBLESHOOTING.md)               |
| Observability and tracing     | [modules/observability/docs/OBSERVABILITY.md](modules/observability/docs/OBSERVABILITY.md)  |
| Dashboards and trace guide    | [docs/DASHBOARDS.md](docs/DASHBOARDS.md)                                                   |


## Tested Versions


| Component                        | Version |
| -------------------------------- | ------- |
| OpenShift                        | 4.20.8  |
| RHOAI                            | 3.3.1   |
| Red Hat Connectivity Link        | 1.3.2   |
| cert-manager                     | 1.18.1  |
| LeaderWorkerSet                  | 1.0.0   |
| OpenShift GitOps (ArgoCD)        | 1.20.1  |
| Grafana Operator                 | 5.22.2  |
| Red Hat build of OpenTelemetry   | 0.20.0  |
| Red Hat build of Tempo           | 0.20.0  |


