---
description: "Bootstrap a fresh OpenShift cluster with all modules. Deploys via ArgoCD by default, or via Helm on request. Runs tests and reports summary."
user_invocable: true
---

# Cluster Bootstrap

Deploy all modules on a fresh cluster and validate the installation with tests.

**Default mode: ArgoCD** (app-of-apps). Use Helm when the user explicitly asks or the repo has no remote.

## Prerequisites

```bash
oc whoami
oc cluster-info
helm version --short
```

## Common: Auto-detect clusterDomain

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
```

Never ask the user for this value.

## Mode A: ArgoCD (default)

1. Pre-flight checks (oc, helm, ArgoCD running, git remote)
2. Auto-detect clusterDomain
3. `make lint`
4. Configure and apply app-of-apps with clusterDomain
5. Wait for ArgoCD sync (all applications Synced+Healthy)
6. Wait for model pods (Running+Ready)
7. `make test-all`
8. Report summary

## Mode B: Helm (explicit request only)

1. Pre-flight checks
2. Auto-detect clusterDomain
3. `make lint`
4. Deploy operators (wave 0): `helm upgrade --install maas-operators ...`
5. Wait for CSVs Succeeded, adopt operator-created resources
6. Deploy platform (wave 1): `helm upgrade --install maas-platform ...`
7. Deploy models (wave 2): `helm upgrade --install maas-model ...`
8. `make test-all`
9. Report summary

## Report Format

```markdown
## Cluster Bootstrap Summary

| Step | Status | Details |
|------|--------|---------|
| Pre-flight | PASS/FAIL | cluster: <api-url>, user: <username> |
| clusterDomain | PASS | <detected-domain> |
| Helm lint | PASS/FAIL | all charts / <error> |
| Deploy method | ArgoCD / Helm | <mode used> |
| Operators | PASS/FAIL | CSVs Succeeded / <issue> |
| Platform | PASS/FAIL | DSCI + DSC + Gateway ready / <issue> |
| Models | PASS/FAIL | N predictor pods running / <issue> |
| Tests | PASS/FAIL | <passed>/<total> tests passed |

**Overall: BOOTSTRAP COMPLETE** or **BOOTSTRAP FAILED**
```

## Troubleshooting

- **ArgoCD app stuck OutOfSync**: `oc get application <name> -n openshift-gitops -o yaml`
- **Operator stuck**: `oc get csv -A | grep -i <operator>`
- **CRD not found**: Operator not installed yet; wait
- **Helm ownership conflict**: Adopt resource with labels/annotations
- **Namespace not found**: Pre-create with `oc create ns <ns>`
- **KServe webhook unavailable**: DSC not Ready yet; wait
