---
description: Deploy a module via Helm (for testing) or ArgoCD (for stable deployment). Includes verification steps.
user_invocable: true
---

# Deploy Module

Deploy a specific module from the project.

## Process

### 1. Identify Module

If the user specified a module (e.g., "deploy maas"), use it. Otherwise ask:

> **Which module do you want to deploy?** (e.g., maas, observability, evaluation)

### 2. Choose Deployment Method

Ask:

> **Deploy with Helm (for testing) or ArgoCD (for stable)?**

### 3a. Helm Deployment (Testing)

This is the preferred method for new or in-development modules.

1. **Dry-run validation:**
   ```bash
   helm template modules/<name>/charts/<chart>
   ```

2. **Install:**
   ```bash
   helm install <release> modules/<name>/charts/<chart> -n <namespace> --create-namespace
   ```
   Or use the Makefile: `make deploy-<name>`

3. **Verify deployment:**
   ```bash
   oc get pods -n <namespace>
   ```

4. **Run tests:**
   ```bash
   make test-<name>
   ```

### 3b. ArgoCD Deployment (Stable)

For modules that have been validated with Helm and are ready for GitOps.

1. **Enable module** in `argocd/apps/values.yaml`:
   ```yaml
   modules:
     <name>:
       enabled: true
   ```

2. **Apply app-of-apps** (if not already deployed):
   ```bash
   oc apply -f argocd/app-of-apps.yaml
   ```
   Or commit and push for automated sync.

3. **Monitor sync:**
   ```bash
   oc get applications -n openshift-gitops
   ```

4. **Run tests:**
   ```bash
   make test-<name>
   ```

### 4. Troubleshooting

If deployment fails:
1. Check ArgoCD app status: `oc get application <app-name> -n openshift-gitops -o yaml`
2. Check pod events: `oc get events -n <namespace> --sort-by=.lastTimestamp`
3. Check operator logs if CRDs are involved
4. See `modules/<name>/docs/` for module-specific troubleshooting
