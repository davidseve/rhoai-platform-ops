---
name: deploy-module
description: "Deploy a module via Helm (for testing) or ArgoCD (for stable deployment). Includes dry-run validation, explicit confirmation, and verification steps."
user_invocable: true
---

# Deploy Module

Deploy a specific module from the project with explicit confirmation at each step.

## Invocation

`/deploy-module [module]`

## Prerequisites

```bash
oc whoami
oc cluster-info
helm version --short
```

If not logged in, **stop** and ask the user to authenticate.

## Process

### 1. Identify Module

If the user specified a module (e.g., `/deploy-module maas`), use it. Otherwise ask:

> **Which module do you want to deploy?** (e.g., maas, observability, evaluation)

### 2. Choose Deployment Method

Ask:

> **Deploy with Helm (for testing) or ArgoCD (for stable)?**

### 3a. Helm Deployment (Testing)

#### Step 1: Dry-run validation (automatic)

```bash
helm template modules/<name>/charts/<chart>
helm lint modules/<name>/charts/<chart>
```

Show the user the rendered output summary (resource count, types).

#### Step 2: Confirm before install

> **About to install to namespace `<namespace>` on cluster `<api-url>`. Proceed? [y/N]**

#### Step 3: Install

```bash
make deploy-<name>
```

Or directly:

```bash
helm upgrade --install <release> modules/<name>/charts/<chart> -n <namespace> --create-namespace --wait --timeout 10m
```

#### Step 4: Verify

```bash
oc get pods -n <namespace>
oc get svc -n <namespace>
```

#### Step 5: Run tests

```bash
make test-<name>
```

### 3b. ArgoCD Deployment (Stable)

#### Step 1: Enable module

Show the change to `argocd/apps/values.yaml` and confirm:

```yaml
modules:
  <name>:
    enabled: true
```

#### Step 2: Apply

```bash
oc apply -f argocd/app-of-apps.yaml
```

Or commit and push for automated sync (ask which method).

#### Step 3: Monitor

```bash
oc get applications -n openshift-gitops
```

Wait for `Synced` + `Healthy`.

#### Step 4: Run tests

```bash
make test-<name>
```

### 4. Troubleshooting

If deployment fails:

1. Check ArgoCD app status: `oc get application <app-name> -n openshift-gitops -o yaml`
2. Check pod events: `oc get events -n <namespace> --sort-by=.lastTimestamp`
3. Check operator logs if CRDs are involved
4. See `modules/<name>/docs/` for module-specific troubleshooting

### 5. Report

```
Deployment complete:
- Method: Helm/ArgoCD
- Module: <name>
- Namespace: <namespace>
- Status: <pods running/healthy>
- Tests: <pass/fail>
```

## Token-efficient execution

For long deploys (`helm upgrade --wait`, multi-step Makefile), follow skill **`long-running-scripts`** (`~/.cursor/skills/long-running-scripts/`):

- One Bash call per phase; no polling or repeated log reads
- Read `.agent-status/*.json` before log files
- On failure only: `tail -50` of the log path from status JSON

## Safety Rules

- ALWAYS show a dry-run before installing
- ALWAYS ask for confirmation before any `helm install/upgrade` or `oc apply`
- NEVER delete resources as part of a deploy flow
- If anything fails, stop and report — do not retry automatically
