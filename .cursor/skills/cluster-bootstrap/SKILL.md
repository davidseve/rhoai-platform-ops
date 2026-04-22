---
name: cluster-bootstrap
description: >-
  Bootstrap a fresh OpenShift cluster with all rhoai-platform-ops modules.
  Deploys via ArgoCD app-of-apps by default, or via Helm if the user
  explicitly requests it. Runs the full test suite and reports a summary.
  Use when the user says "new cluster", "bootstrap", "initial setup",
  "install everything", "deploy all", "instala el cluster", or similar.
---

# Cluster Bootstrap

Deploy all modules on a fresh cluster and validate the installation with tests.

**Default mode: ArgoCD** (app-of-apps). Use Helm when:
- The user explicitly says "deploy with helm", "helm install", or similar
- The git repo has no commits or is not accessible (ArgoCD needs a remote repo)

## Prerequisites

Before starting, verify:

1. **`oc` is logged in** to the target cluster with cluster-admin privileges:
   ```bash
   oc whoami
   oc cluster-info
   ```
2. **`helm` is available** (v3+):
   ```bash
   helm version --short
   ```
3. **Cluster is "fresh"**: no previous rhoai-platform-ops resources. If unsure,
   offer to run the `cluster-cleanup` skill first.

If any prerequisite fails, stop and tell the user what is missing.

## Common: Auto-detect clusterDomain

Both modes need the cluster ingress domain. Always detect it automatically:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "Detected clusterDomain: $CLUSTER_DOMAIN"
```

Never ask the user for this value; read it from the cluster.

---

## Mode A: ArgoCD (default)

### Process

```
Bootstrap Progress (ArgoCD):
- [ ] Step 1: Pre-flight checks
- [ ] Step 2: Auto-detect clusterDomain
- [ ] Step 3: Helm lint (dry-run validation)
- [ ] Step 4: Configure and apply app-of-apps
- [ ] Step 5: Wait for ArgoCD sync
- [ ] Step 6: Wait for model pods
- [ ] Step 7: Run tests
- [ ] Step 8: Report summary
```

### Step 1 -- Pre-flight Checks

```bash
oc whoami
oc cluster-info
helm version --short
```

Verify ArgoCD is running:

```bash
oc get pods -n openshift-gitops | grep argocd-server
```

Verify the git repo is accessible (ArgoCD needs a remote with commits):

```bash
git log --oneline -1 2>/dev/null || echo "WARNING: no commits in repo"
git remote -v 2>/dev/null
```

If the repo has **no commits** or **no remote**, ArgoCD cannot sync. Fall back to
Helm mode automatically and inform the user.

Print cluster API URL and logged-in user so the operator can confirm.

### Step 2 -- Auto-detect clusterDomain

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
```

### Step 3 -- Helm Lint

```bash
make lint
```

(`make template` will fail because clusterDomain is empty in defaults -- that is
expected and not an error.)

### Step 4 -- Configure and Apply App-of-Apps

Update the `clusterDomain` in `argocd/app-of-apps.yaml` to match the detected
value, then apply:

```bash
sed -i "s|value: .*|value: $CLUSTER_DOMAIN|" argocd/app-of-apps.yaml
oc apply -f argocd/app-of-apps.yaml
```

**Do NOT commit** the `sed` change -- it is a local cluster-specific override.

### Step 5 -- Wait for ArgoCD Sync

Wait for all ArgoCD Applications to reach `Synced` + `Healthy`. The apps deploy
in wave order (operators -> platform -> models) with automatic retries.

```bash
for app in maas-operators maas-platform maas-model maas-model-fast; do
  echo "Waiting for $app..."
  oc wait application "$app" -n openshift-gitops \
    --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout=20m 2>/dev/null || echo "$app not healthy yet"
done
```

Poll `oc get applications -n openshift-gitops` every 30-60s and report progress.
ArgoCD handles wave ordering, retries, `ServerSideApply`, and
`SkipDryRunOnMissingResource` natively -- no manual adoption or waiting needed.

If an Application stays `Degraded` or `OutOfSync` after 15 minutes:

```bash
oc get application <app-name> -n openshift-gitops -o yaml | tail -40
```

### Step 6 -- Wait for Model Pods

Even after ArgoCD reports Healthy, model pods may still be pulling images.

```bash
oc get pods -n maas-models
```

Wait until all predictor pods show `Running` + `Ready` (2/2).

### Step 7 -- Run Tests

```bash
make test-all
```

### Step 8 -- Report Summary

See [Report format](#report-format) below.

---

## Mode B: Helm (only when explicitly requested)

### Process

```
Bootstrap Progress (Helm):
- [ ] Step 1: Pre-flight checks
- [ ] Step 2: Auto-detect clusterDomain
- [ ] Step 3: Helm lint
- [ ] Step 4: Deploy operators (wave 0)
- [ ] Step 5: Wait for operators + adopt resources
- [ ] Step 6: Deploy platform (wave 1) + wait DSC Ready
- [ ] Step 7: Deploy models (wave 2) + wait pods Ready
- [ ] Step 8: Run tests
- [ ] Step 9: Report summary
```

### Step 1-3

Same as ArgoCD mode (pre-flight, clusterDomain, lint).

### Step 4 -- Deploy Operators (wave 0)

```bash
helm upgrade --install maas-operators modules/maas/charts/operators \
  --wait --timeout 10m
```

### Step 5 -- Wait for Operators + Adopt Pre-existing Resources

Operators auto-create certain resources (DSCInitialization, GatewayClass,
Limitador) that the platform chart also manages. Helm requires explicit
ownership, so these must be adopted before deploying the platform chart.

Wait for all CSVs to reach `Succeeded`:

```bash
echo "Waiting for operator CSVs..."
for i in $(seq 1 30); do
  pending=$(oc get csv -n kuadrant-system -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -cv Succeeded || true)
  if [ "$pending" -eq 0 ]; then echo "All CSVs Succeeded"; break; fi
  echo "  $pending CSVs still installing..."; sleep 10
done
```

Verify operator pods are Running:

```bash
oc get pods -n redhat-ods-operator
oc get pods -n kuadrant-system
oc get pods -n leader-worker-set
```

**Adopt operator-created resources into the platform Helm release:**

```bash
ADOPT_RESOURCES=(
  "dscinitialization/default-dsci"
  "gatewayclass/openshift-default"
  "limitador/limitador -n kuadrant-system"
)

for res in "${ADOPT_RESOURCES[@]}"; do
  echo "Adopting: $res"
  oc label $res app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
  oc annotate $res meta.helm.sh/release-name=maas-platform \
    meta.helm.sh/release-namespace=default --overwrite 2>/dev/null || true
done
```

Some resources may not exist yet (e.g. DSCInitialization takes a few seconds).
Retry with a short sleep if needed.

### Step 6 -- Deploy Platform (wave 1)

The platform chart creates resources in `redhat-ods-applications` (OdhDashboardConfig,
tier-to-group-mapping ConfigMap). On a fresh cluster the RHOAI operator only creates
this namespace after a DSCInitialization is reconciled, so pre-create it:

```bash
oc create ns redhat-ods-applications --dry-run=client -o yaml | oc apply -f -
```

If there are stuck Helm release secrets from a previous failed cleanup, remove them:

```bash
oc delete secret -n default -l name=maas-platform,owner=helm --ignore-not-found
```

Deploy:

```bash
helm upgrade --install maas-platform modules/maas/charts/maas-platform \
  --set clusterDomain=$CLUSTER_DOMAIN --wait --timeout 15m
```

Wait for DSC to become Ready (required for KServe webhook):

```bash
echo "Waiting for DSC Ready..."
for i in $(seq 1 30); do
  status=$(oc get dsc default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$status" = "True" ]; then echo "DSC is Ready"; break; fi
  echo "  DSC not ready yet..."; sleep 30
done
```

Verify KServe webhook has endpoints before proceeding to models:

```bash
oc get endpoints kserve-webhook-server-service -n redhat-ods-applications
```

### Step 7 -- Deploy Models (wave 2)

Deploy the first model:

```bash
helm upgrade --install maas-model modules/maas/charts/maas-model \
  --wait --timeout 15m
```

The second model release shares hook resources (`patch-gateway-authn` SA, Role,
RoleBinding, Job in `openshift-ingress`) with the first. Transfer ownership
before installing:

```bash
for kind in serviceaccount role rolebinding; do
  oc annotate $kind patch-gateway-authn -n openshift-ingress \
    meta.helm.sh/release-name=maas-model-fast --overwrite 2>/dev/null || true
done
oc delete job patch-gateway-authn -n openshift-ingress --ignore-not-found
```

Deploy the second model:

```bash
helm upgrade --install maas-model-fast modules/maas/charts/maas-model \
  -f modules/maas/charts/maas-model/values-tinyllama-fast.yaml \
  --wait --timeout 15m
```

Wait for all predictor pods to be Running (2/2):

```bash
oc get pods -n maas-models
```

### Step 8-9

Same as ArgoCD mode (tests + summary).

---

## Report Format

```markdown
## Cluster Bootstrap Summary

| Step | Status | Details |
|------|--------|---------|
| Pre-flight | PASS/FAIL | cluster: <api-url>, user: <username> |
| clusterDomain | PASS | <detected-domain> |
| Helm lint | PASS/FAIL | all charts / <error> |
| Deploy method | ArgoCD / Helm | <mode used> |
| Operators | PASS/FAIL | CSVs Succeeded, pods Running / <issue> |
| Platform | PASS/FAIL | DSCI + DSC + Gateway ready / <issue> |
| Models | PASS/FAIL | N predictor pods running / <issue> |
| Tests | PASS/FAIL | <passed>/<total> tests passed |

**Overall: BOOTSTRAP COMPLETE** or **BOOTSTRAP FAILED -- see issues below**

### Issues (if any)
[List failures with key error details and suggested fixes]
```

## Adding New Modules

When a new module is added to the project, update this skill:

1. Add the module's ArgoCD Application template (and Helm deploy command)
2. Add verification checks for the module's key resources
3. Add the module's test target to the test step
4. Update the summary table
5. If the module has operator-created resources that need Helm adoption, add them
   to the `ADOPT_RESOURCES` list in the Helm flow

Keep the wave ordering: operators (wave 0) -> platform (wave 1) -> workloads (wave 2).

## Troubleshooting

- **ArgoCD app stuck `OutOfSync`**: Check sync errors with
  `oc get application <name> -n openshift-gitops -o yaml`
- **Operator stuck**: Check CSV status with `oc get csv -A | grep -i <operator>`
- **CRD not found**: Operator hasn't finished installing; wait or check operator logs
- **Helm ownership conflict**: Adopt the resource (label + annotate) as shown in Step 5
- **Helm "has no deployed releases"**: A previous release is stuck in `uninstalling`
  or `pending-install` state. Delete the release secret:
  `oc delete secret -n default -l name=<release>,owner=helm`
- **Namespace not found (redhat-ods-applications)**: RHOAI operator hasn't created it
  yet. Pre-create with `oc create ns redhat-ods-applications`
- **ArgoCD "remote repository is empty"**: The git repo has no commits. Fall back to
  Helm mode or push the code first
- **KServe webhook unavailable**: DSC is not Ready yet; wait and retry
- **Pod ImagePullBackOff**: Verify image pull secrets and registry access
- **Gateway not ready**: Check Kuadrant readiness hook logs
- **Tests fail**: Run individual test files for targeted debugging:
  ```bash
  cd modules/maas/tests && pytest test_01_inference.py -v
  ```

For module-specific issues, see `modules/<name>/docs/TROUBLESHOOTING.md`.
