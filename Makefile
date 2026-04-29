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

# --- MaaS Module ---

.PHONY: deploy-maas
deploy-maas: ## Deploy MaaS operators + platform + models via Helm
	$(HELM) upgrade --install maas-operators modules/maas/charts/operators --wait --timeout 10m
	$(HELM) upgrade --install maas-platform modules/maas/charts/maas-platform \
		--set grafana.enabled=$(GRAFANA_ENABLED) --wait --timeout 15m
	$(HELM) upgrade --install maas-model modules/maas/charts/maas-model --wait --timeout 15m
	$(HELM) upgrade --install maas-model-fast modules/maas/charts/maas-model -f modules/maas/charts/maas-model/values-tinyllama-fast.yaml --wait --timeout 15m

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

.PHONY: wait-healthy
wait-healthy: ## Wait for all ArgoCD apps to be Synced+Healthy and model pods Ready
	@echo "Waiting for ArgoCD applications to sync (timeout: $(WAIT_TIMEOUT)m)..."
	@elapsed=0; \
	while [ $$elapsed -lt $$(($(WAIT_TIMEOUT) * 60)) ]; do \
		total=$$($(OC) get applications -n openshift-gitops --no-headers 2>/dev/null | wc -l); \
		healthy=$$($(OC) get applications -n openshift-gitops --no-headers 2>/dev/null | grep -c "Synced.*Healthy" || true); \
		echo "  [$$((elapsed / 60))m$${elapsed##*[0-9]}] $$healthy/$$total apps Synced+Healthy"; \
		if [ "$$total" -gt 0 ] && [ "$$healthy" -eq "$$total" ]; then \
			echo "All ArgoCD applications are Synced+Healthy."; \
			break; \
		fi; \
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
		not_ready=$$($(OC) get pods -n maas-models --no-headers 2>/dev/null | grep -cv "Running" || true); \
		if [ "$$not_ready" -eq 0 ]; then \
			$(OC) get pods -n maas-models; \
			echo "All model pods are Running."; \
			break; \
		fi; \
		echo "  [$$((elapsed / 60))m] $$not_ready pod(s) not ready yet..."; \
		sleep $(WAIT_INTERVAL); \
		elapsed=$$((elapsed + $(WAIT_INTERVAL))); \
	done; \
	if [ $$elapsed -ge $$(($(WAIT_TIMEOUT) * 60)) ]; then \
		echo "ERROR: Timed out waiting for model pods."; \
		$(OC) get pods -n maas-models; \
		exit 1; \
	fi

.PHONY: bootstrap-argocd
bootstrap-argocd: deploy-argocd wait-healthy test-all ## Deploy ArgoCD app-of-apps, wait for sync, run tests

.PHONY: undeploy-argocd
undeploy-argocd: ## Remove app-of-apps
	$(OC) delete -f argocd/app-of-apps.yaml --ignore-not-found

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

.PHONY: cluster-cleanup-dry
cluster-cleanup-dry: ## Dry-run: show what cluster-cleanup would delete
	DRY_RUN=true ./scripts/cluster-cleanup.sh

# --- All Modules ---

.PHONY: deploy-all
deploy-all: deploy-observability ## Deploy all enabled modules
	$(MAKE) deploy-maas GRAFANA_ENABLED=true

.PHONY: test-all
test-all: test-observability test-maas ## Run all module tests

.PHONY: undeploy-all
undeploy-all: undeploy-maas undeploy-observability ## Undeploy all modules

# --- Validation ---

.PHONY: template
template: ## Helm template dry-run for all charts
	$(HELM) template obs-operators modules/observability/charts/operators
	$(HELM) template obs-grafana modules/observability/charts/grafana
	$(HELM) template obs-tracing modules/observability/charts/tracing
	$(HELM) template maas-operators modules/maas/charts/operators
	$(HELM) template maas-platform modules/maas/charts/maas-platform
	$(HELM) template maas-model modules/maas/charts/maas-model
	$(HELM) template argocd-apps argocd/apps

.PHONY: lint
lint: ## Helm lint all charts
	$(HELM) lint modules/observability/charts/operators
	$(HELM) lint modules/observability/charts/grafana
	$(HELM) lint modules/observability/charts/tracing
	$(HELM) lint modules/maas/charts/operators
	$(HELM) lint modules/maas/charts/maas-platform
	$(HELM) lint modules/maas/charts/maas-model
	$(HELM) lint argocd/apps

# --- Help ---

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
