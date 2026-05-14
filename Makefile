# rhoai-platform-ops Makefile
# Per-module targets for Helm-first workflow + ArgoCD stable deployment.

HELM ?= helm
OC ?= oc
PYTHON ?= python3
GRAFANA_ENABLED ?= false
BRANCH ?=

# --- Observability Module ---

.PHONY: deploy-observability
deploy-observability: ## Deploy observability (operators + Grafana + tracing)
	$(HELM) upgrade --install obs-operators modules/observability/charts/operators --wait --timeout 10m
	@echo "Waiting for Grafana CRDs..."
	$(OC) wait --for=condition=Established crd grafanas.grafana.integreatly.org --timeout=120s
	$(HELM) upgrade --install obs-grafana modules/observability/charts/grafana --wait --timeout 10m
	@echo "Waiting for Tempo/OTel CRDs..."
	$(OC) wait --for=condition=Established crd tempomonolithics.tempo.grafana.com --timeout=120s
	$(OC) wait --for=condition=Established crd opentelemetrycollectors.opentelemetry.io --timeout=120s
	$(HELM) upgrade --install obs-tracing modules/observability/charts/tracing --wait --timeout 10m
	$(HELM) upgrade --install obs-grafana modules/observability/charts/grafana --wait --timeout 10m

.PHONY: test-observability
test-observability: ## Run Observability E2E tests
	$(PYTHON) -m venv modules/observability/tests/.venv
	modules/observability/tests/.venv/bin/pip install -q -r modules/observability/tests/requirements.txt
	modules/observability/tests/.venv/bin/pytest modules/observability/tests/ -v; \
	  rc=$$?; rm -rf modules/observability/tests/.venv; exit $$rc

.PHONY: undeploy-observability
undeploy-observability: ## Undeploy observability via Helm
	-$(HELM) uninstall obs-tracing 2>/dev/null
	-$(HELM) uninstall obs-grafana 2>/dev/null
	-$(HELM) uninstall obs-operators 2>/dev/null

# --- Database Module ---

.PHONY: deploy-database
deploy-database: ## Deploy shared PostgreSQL database via Helm
	@$(OC) get ns redhat-ods-applications &>/dev/null || $(OC) create ns redhat-ods-applications
	$(HELM) upgrade --install database modules/database/charts/database --wait --timeout 5m
	@echo "Waiting for PostgreSQL pod..."
	@$(OC) wait --for=condition=Ready pod -l app=maas-db -n redhat-ods-applications --timeout=120s

.PHONY: undeploy-database
undeploy-database: ## Undeploy shared PostgreSQL database via Helm
	-$(HELM) uninstall database 2>/dev/null

# --- MaaS Module ---

.PHONY: deploy-maas
deploy-maas: ## Deploy MaaS operators + platform + models via Helm
	@echo "=== Phase 1: Operators (subscriptions only) ==="
	$(HELM) upgrade --install maas-operators modules/maas/charts/operators --wait --timeout 10m
	@echo "Waiting for operator CRDs..."
	@for crd in datascienceclusters.datasciencecluster.opendatahub.io dscinitializations.dscinitialization.opendatahub.io limitadors.limitador.kuadrant.io kuadrants.kuadrant.io leaderworkersetoperators.operator.openshift.io; do \
		echo "  Waiting for $$crd..."; \
		for i in $$(seq 1 60); do \
			if $(OC) wait --for=condition=Established crd/$$crd --timeout=5s 2>/dev/null; then \
				break; \
			fi; \
			if [ $$i -eq 60 ]; then echo "ERROR: CRD $$crd not found after 5 minutes"; exit 1; fi; \
			sleep 5; \
		done; \
	done
	@echo "=== Phase 2: Platform (operator CRs, DSC, Gateway, monitoring) ==="
	$(HELM) upgrade --install maas-platform modules/maas/charts/maas-platform \
		--set grafana.enabled=$(GRAFANA_ENABLED) --wait --timeout 15m
	@echo "Waiting for DSC to be Ready..."
	@for i in $$(seq 1 120); do \
		status=$$($(OC) get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null); \
		if [ "$$status" = "True" ]; then echo "  DSC Ready."; break; fi; \
		echo "  [$$((i * 5))s] DSC Ready=$$status"; \
		if [ $$i -eq 120 ]; then echo "ERROR: DSC not Ready after 10 minutes"; exit 1; fi; \
		sleep 5; \
	done
	@echo "Waiting for OdhDashboardConfig..."
	@for i in $$(seq 1 60); do \
		if $(OC) get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null; then \
			echo "  OdhDashboardConfig ready."; \
			break; \
		fi; \
		if [ $$i -eq 60 ]; then echo "WARNING: OdhDashboardConfig not found after 5 minutes, skipping patch"; fi; \
		sleep 5; \
	done
	@echo "=== Phase 3: Dashboard config + Models ==="
	@$(OC) get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications &>/dev/null && \
		$(OC) patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
			--type=merge -p '{"spec":{"dashboardConfig":{"genAiStudio":true,"modelAsService":true}}}' || \
		echo "  Skipping dashboard patch (OdhDashboardConfig not found)"
	$(HELM) upgrade --install maas-model modules/maas/charts/maas-model \
		--set namespace.create=false --wait --timeout 15m
	$(HELM) upgrade --install maas-model-fast modules/maas/charts/maas-model \
		-f modules/maas/charts/maas-model/values-tinyllama-fast.yaml \
		--set namespace.create=false --wait --timeout 15m

.PHONY: test-maas
test-maas: ## Run MaaS E2E tests
	$(PYTHON) -m venv modules/maas/tests/.venv
	modules/maas/tests/.venv/bin/pip install -q -r modules/maas/tests/requirements.txt
	modules/maas/tests/.venv/bin/pytest modules/maas/tests/ -v; \
	  rc=$$?; rm -rf modules/maas/tests/.venv; exit $$rc

.PHONY: undeploy-maas
undeploy-maas: ## Undeploy MaaS via Helm
	-$(HELM) uninstall maas-model-fast 2>/dev/null
	-$(HELM) uninstall maas-model 2>/dev/null
	-$(HELM) uninstall maas-platform 2>/dev/null
	-$(HELM) uninstall maas-operators 2>/dev/null

# --- Evaluation Module (includes GuideLLM benchmarks, see ADR-0007) ---

.PHONY: deploy-evaluation
deploy-evaluation: ## Deploy evaluation (EvalHub + MLflow) via Helm
	$(HELM) upgrade --install evaluation modules/evaluation/charts/evaluation --timeout 5m

.PHONY: test-evaluation
test-evaluation: ## Run Evaluation E2E tests
	$(PYTHON) -m venv modules/evaluation/tests/.venv
	modules/evaluation/tests/.venv/bin/pip install -q -r modules/evaluation/tests/requirements.txt
	modules/evaluation/tests/.venv/bin/pytest modules/evaluation/tests/ -v; \
	  rc=$$?; rm -rf modules/evaluation/tests/.venv; exit $$rc

.PHONY: undeploy-evaluation
undeploy-evaluation: ## Undeploy evaluation via Helm
	-$(HELM) uninstall evaluation 2>/dev/null

# --- EvalHub API (primary evaluation interface, see ADR-0008) ---

EVALHUB_BENCHMARK ?= arc_easy
EVALHUB_PROVIDER ?= lm_evaluation_harness
MODEL_URL ?=
MODEL_NAME ?= tinyllama-fast
TOKENIZER ?= TinyLlama/TinyLlama-1.1B-Chat-v1.0
SECRET_REF ?= model-auth
EVAL_LIMIT ?= 10
JOB_ID ?=

.PHONY: evalhub-eval
evalhub-eval: ## Run quality evaluation via EvalHub API (EVALHUB_BENCHMARK=arc_easy, MODEL_URL=url, EVAL_LIMIT=10)
	./scripts/evalhub.sh submit \
		--provider lm_evaluation_harness \
		--benchmark $(EVALHUB_BENCHMARK) \
		--model-url $(MODEL_URL) \
		--model-name $(MODEL_NAME) \
		$(if $(TOKENIZER),--tokenizer $(TOKENIZER)) \
		$(if $(SECRET_REF),--secret-ref $(SECRET_REF)) \
		$(if $(EVAL_LIMIT),--limit $(EVAL_LIMIT)) \
		--wait

.PHONY: evalhub-benchmark
evalhub-benchmark: ## Run performance benchmark via EvalHub API (EVALHUB_BENCHMARK=sweep, MODEL_URL=url)
	./scripts/evalhub.sh submit \
		--provider guidellm \
		--benchmark $(EVALHUB_BENCHMARK) \
		--model-url $(MODEL_URL) \
		--model-name $(MODEL_NAME) \
		$(if $(SECRET_REF),--secret-ref $(SECRET_REF)) \
		--wait

.PHONY: evalhub-status
evalhub-status: ## Check EvalHub job status (JOB_ID=uuid)
	./scripts/evalhub.sh status $(JOB_ID)

.PHONY: evalhub-jobs
evalhub-jobs: ## List all EvalHub evaluation jobs
	./scripts/evalhub.sh jobs

.PHONY: evalhub-providers
evalhub-providers: ## List available EvalHub providers and benchmarks
	./scripts/evalhub.sh providers

.PHONY: evalhub-collections
evalhub-collections: ## List available EvalHub benchmark collections
	./scripts/evalhub.sh collections

# --- Legacy evaluation targets (DEPRECATED: use evalhub-* targets instead) ---

EVAL_TASK ?= arc_easy
EVAL_MODEL_URL ?=

.PHONY: run-evaluation
run-evaluation: ## [DEPRECATED] Run LMEvalJob directly — use 'make evalhub-eval' instead
	@echo "WARNING: run-evaluation is deprecated. Use 'make evalhub-eval' instead." >&2
	@echo "=== Running LMEvalJob: $(EVAL_TASK) (limit=$(EVAL_LIMIT)) ==="
	@EVAL_YAML=$$($(HELM) template evaluation modules/evaluation/charts/evaluation \
		--set lmeval.enabled=true \
		--set lmeval.task=$(EVAL_TASK) \
		--set lmeval.limit=$(EVAL_LIMIT) \
		$(if $(EVAL_MODEL_URL),--set lmeval.modelUrl=$(EVAL_MODEL_URL)) \
		--show-only templates/lmevaljob.yaml); \
	echo "$$EVAL_YAML" | $(OC) create -f -

BENCHMARK_SCENARIO ?= gateway
BENCHMARK_TARGET ?=
BENCHMARK_TOKEN ?=

.PHONY: run-benchmark
run-benchmark: ## [DEPRECATED] Run GuideLLM Job directly — use 'make evalhub-benchmark' instead
	@echo "WARNING: run-benchmark is deprecated. Use 'make evalhub-benchmark' instead." >&2
	@echo "=== Running benchmark scenario: $(BENCHMARK_SCENARIO) ==="
	@JOB_YAML=$$($(HELM) template evaluation modules/evaluation/charts/evaluation \
		--set benchmarks.job.enabled=true \
		$(if $(filter baseline stress slo,$(BENCHMARK_SCENARIO)),-f modules/evaluation/charts/evaluation/values-$(BENCHMARK_SCENARIO).yaml) \
		$(if $(BENCHMARK_TARGET),--set benchmarks.benchmark.target=$(BENCHMARK_TARGET)) \
		$(if $(BENCHMARK_TOKEN),--set benchmarks.benchmark.authToken=$(BENCHMARK_TOKEN)) \
		--show-only templates/benchmarks-job.yaml); \
	JOB_NAME=$$(echo "$$JOB_YAML" | grep "^  name:" | head -1 | awk '{print $$2}'); \
	echo "$$JOB_YAML" | $(OC) create -f - && \
	echo "Waiting for job/$$JOB_NAME to complete..." && \
	$(OC) wait --for=condition=complete job/$$JOB_NAME -n evaluation --timeout=1800s && \
	echo "=== Job completed ===" && \
	$(OC) logs job/$$JOB_NAME -n evaluation

# --- ArgoCD (Stable Deployment) ---

.PHONY: deploy-argocd
deploy-argocd: ## Deploy app-of-apps via ArgoCD
	$(OC) apply -f argocd/app-of-apps.yaml

.PHONY: status
status: ## Check ArgoCD application sync status
	$(OC) get applications.argoproj.io -n openshift-gitops

.PHONY: argocd-branch-current
argocd-branch-current: ## Point ArgoCD manifests to the current git branch
	$(PYTHON) scripts/set_target_revision.py --current

.PHONY: argocd-branch-main
argocd-branch-main: ## Point ArgoCD manifests back to main
	$(PYTHON) scripts/set_target_revision.py --main

.PHONY: argocd-branch
argocd-branch: ## Point ArgoCD manifests to BRANCH=<name>
	@if [ -z "$(BRANCH)" ]; then \
		echo "Usage: make argocd-branch BRANCH=<branch-name>"; \
		exit 1; \
	fi
	$(PYTHON) scripts/set_target_revision.py --branch "$(BRANCH)"

WAIT_TIMEOUT ?= 20
WAIT_INTERVAL ?= 30
# parent + 10 child apps (database, maas-operators, maas-platform, maas-model, maas-model-fast, obs-operators, obs-grafana, obs-tracing, evaluation)
MIN_APPS ?= 10
APP_FILTER = grep -E 'maas-|observability-|rhoai-platform-ops|evaluation|database'

.PHONY: wait-healthy
wait-healthy: ## Wait for all ArgoCD apps to be Synced+Healthy and model pods Ready
	@echo "Waiting for ArgoCD applications to sync (timeout: $(WAIT_TIMEOUT)m, expect >= $(MIN_APPS) apps)..."
	@elapsed=0; \
	while [ $$elapsed -lt $$(($(WAIT_TIMEOUT) * 60)) ]; do \
		total=$$($(OC) get applications -n openshift-gitops --no-headers 2>/dev/null | $(APP_FILTER) | wc -l); \
		healthy=$$($(OC) get applications -n openshift-gitops --no-headers 2>/dev/null | $(APP_FILTER) | grep -c "Synced.*Healthy" || true); \
		if [ "$$total" -ge $(MIN_APPS) ] && [ "$$healthy" -eq "$$total" ]; then \
			echo "  [$$((elapsed / 60))m] $$healthy/$$total apps Synced+Healthy"; \
			echo "All ArgoCD applications are Synced+Healthy."; \
			break; \
		fi; \
		not_healthy=$$($(OC) get applications -n openshift-gitops --no-headers 2>/dev/null | $(APP_FILTER) | grep -v "Synced.*Healthy" | awk '{print $$1"("$$2"/"$$3")"}' | tr '\n' ' '); \
		echo "  [$$((elapsed / 60))m] $$healthy/$$total apps Synced+Healthy  pending: $$not_healthy"; \
		for ip in $$($(OC) get installplan -n openshift-operators -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do \
			echo "  Auto-approving InstallPlan $$ip (OLM Manual dependency)..."; \
			$(OC) patch installplan "$$ip" -n openshift-operators --type merge -p '{"spec":{"approved":true}}' 2>/dev/null || true; \
		done; \
		sleep $(WAIT_INTERVAL); \
		elapsed=$$((elapsed + $(WAIT_INTERVAL))); \
	done; \
	if [ $$elapsed -ge $$(($(WAIT_TIMEOUT) * 60)) ]; then \
		echo "ERROR: Timed out waiting for applications."; \
		$(OC) get applications -n openshift-gitops; \
		exit 1; \
	fi
	@echo "Waiting for model pods to be Ready..."
	@elapsed=0; \
	while [ $$elapsed -lt $$(($(WAIT_TIMEOUT) * 60)) ]; do \
		not_ready=$$($(OC) get pods -n models-as-a-service --no-headers 2>/dev/null | grep -cv "Running" || true); \
		if [ "$$not_ready" -eq 0 ] && [ "$$($(OC) get pods -n models-as-a-service --no-headers 2>/dev/null | wc -l)" -gt 0 ]; then \
			$(OC) get pods -n models-as-a-service; \
			echo "All model pods are Running."; \
			break; \
		fi; \
		echo "  [$$((elapsed / 60))m] $$not_ready pod(s) not ready yet..."; \
		sleep $(WAIT_INTERVAL); \
		elapsed=$$((elapsed + $(WAIT_INTERVAL))); \
	done; \
	if [ $$elapsed -ge $$(($(WAIT_TIMEOUT) * 60)) ]; then \
		echo "ERROR: Timed out waiting for model pods."; \
		$(OC) get pods -n models-as-a-service; \
		exit 1; \
	fi
	@echo "Waiting for LLMInferenceService models to be Ready..."
	@elapsed=0; \
	while [ $$elapsed -lt $$(($(WAIT_TIMEOUT) * 60)) ]; do \
		total_models=$$($(OC) get llminferenceservice -n models-as-a-service --no-headers 2>/dev/null | wc -l); \
		ready_models=$$($(OC) get llminferenceservice -n models-as-a-service -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true); \
		if [ "$$total_models" -gt 0 ] && [ "$$ready_models" -eq "$$total_models" ]; then \
			$(OC) get llminferenceservice -n models-as-a-service; \
			echo "All LLMInferenceService models are Ready."; \
			break; \
		fi; \
		not_ready_names=$$($(OC) get llminferenceservice -n models-as-a-service -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status} {end}' 2>/dev/null || true); \
		echo "  [$$((elapsed / 60))m] $$ready_models/$$total_models models Ready  $$not_ready_names"; \
		sleep $(WAIT_INTERVAL); \
		elapsed=$$((elapsed + $(WAIT_INTERVAL))); \
	done; \
	if [ $$elapsed -ge $$(($(WAIT_TIMEOUT) * 60)) ]; then \
		echo "ERROR: Timed out waiting for LLMInferenceService readiness."; \
		$(OC) get llminferenceservice -n models-as-a-service -o wide; \
		exit 1; \
	fi

.PHONY: bootstrap-argocd
bootstrap-argocd: deploy-argocd wait-healthy test-all ## Deploy ArgoCD app-of-apps, wait for sync, run tests

.PHONY: undeploy-argocd
undeploy-argocd: ## Remove app-of-apps
	$(OC) delete -f argocd/app-of-apps.yaml --ignore-not-found

# --- Container Images ---

VLLM_OTEL_IMAGE ?= quay.io/dseveria/vllm-cpu-openai-ubi9
VLLM_OTEL_TAG ?= 0.3-otel

.PHONY: build-vllm-cpu-otel
build-vllm-cpu-otel: ## Build vLLM CPU image with OpenTelemetry packages
	podman build -t $(VLLM_OTEL_IMAGE):$(VLLM_OTEL_TAG) modules/maas/images/vllm-cpu-otel

.PHONY: push-vllm-cpu-otel
push-vllm-cpu-otel: ## Push vLLM CPU OTel image to registry
	podman push $(VLLM_OTEL_IMAGE):$(VLLM_OTEL_TAG)

# --- Traffic Generation ---

.PHONY: generate-traffic
generate-traffic: ## Generate inference traffic for dashboard population
	bash scripts/generate-traffic.sh

# --- Cluster Cleanup ---

.PHONY: cluster-cleanup
cluster-cleanup: ## Remove ALL deployed resources from the cluster
	./scripts/cluster-cleanup.sh --yes

.PHONY: cluster-cleanup-maas
cluster-cleanup-maas: ## Remove only MaaS resources from the cluster
	./scripts/cluster-cleanup.sh --yes maas

.PHONY: cluster-cleanup-observability
cluster-cleanup-observability: ## Remove only observability resources from the cluster
	./scripts/cluster-cleanup.sh --yes observability

.PHONY: cluster-cleanup-evaluation
cluster-cleanup-evaluation: ## Remove only evaluation resources (includes benchmarks) from the cluster
	./scripts/cluster-cleanup.sh --yes evaluation

.PHONY: cluster-cleanup-database
cluster-cleanup-database: ## Remove only database resources from the cluster
	./scripts/cluster-cleanup.sh --yes database

.PHONY: cluster-cleanup-dry
cluster-cleanup-dry: ## Dry-run: show what cluster-cleanup would delete
	DRY_RUN=true ./scripts/cluster-cleanup.sh

.PHONY: full-redeploy
full-redeploy: cluster-cleanup bootstrap-argocd ## Cleanup everything + redeploy via ArgoCD + run tests

# --- All Modules ---

.PHONY: deploy-all
deploy-all: deploy-database deploy-observability ## Deploy all enabled modules
	$(MAKE) deploy-maas GRAFANA_ENABLED=true

.PHONY: test-all
test-all: test-observability test-maas test-evaluation ## Run all module tests

.PHONY: undeploy-all
undeploy-all: undeploy-evaluation undeploy-maas undeploy-observability undeploy-database ## Undeploy all modules

# --- Validation ---

.PHONY: template
template: ## Helm template dry-run for all charts
	$(HELM) template obs-operators modules/observability/charts/operators
	$(HELM) template obs-grafana modules/observability/charts/grafana
	$(HELM) template obs-tracing modules/observability/charts/tracing
	$(HELM) template database modules/database/charts/database
	$(HELM) template maas-operators modules/maas/charts/operators
	$(HELM) template maas-platform modules/maas/charts/maas-platform
	$(HELM) template maas-model modules/maas/charts/maas-model
	$(HELM) template evaluation modules/evaluation/charts/evaluation
	$(HELM) template argocd-apps argocd/apps

.PHONY: lint
lint: ## Helm lint all charts
	$(HELM) lint modules/observability/charts/operators
	$(HELM) lint modules/observability/charts/grafana
	$(HELM) lint modules/observability/charts/tracing
	$(HELM) lint modules/database/charts/database
	$(HELM) lint modules/maas/charts/operators
	$(HELM) lint modules/maas/charts/maas-platform
	$(HELM) lint modules/maas/charts/maas-model
	$(HELM) lint modules/evaluation/charts/evaluation
	$(HELM) lint argocd/apps

# --- Help ---

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
