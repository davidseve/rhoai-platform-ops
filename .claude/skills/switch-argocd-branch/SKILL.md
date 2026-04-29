---
description: "Switch ArgoCD target revisions between main and a feature branch. Use when pointing ArgoCD to the current branch for testing or switching back to main."
user_invocable: true
---

# Switch ArgoCD Branch

Switch Argo CD application target revisions between `main` and the current git branch by updating `argocd/app-of-apps.yaml` and `argocd/apps/values.yaml`.

## What This Changes

Update both branch references together:

- `argocd/app-of-apps.yaml` for the root Application
- `argocd/apps/values.yaml` for the child Applications rendered by Helm

Updating only one of these files is incomplete.

## Workflow

```text
- [ ] Confirm target branch (main or current branch)
- [ ] Verify git branch and remote availability
- [ ] Update both Argo CD manifests
- [ ] Review the diff
- [ ] Apply to the cluster if the user wants the switch now
```

### 1. Confirm the target branch

- **Switch to working branch**: use the current git branch
- **Switch back**: use `main`

### 2. Check branch state

```bash
git branch --show-current
git status --short
git ls-remote --heads origin "$(git branch --show-current)"
```

Rules:
- Warn if the branch is not pushed to origin (ArgoCD cannot sync it)
- If on `main`, confirm whether the user really wants `main` or another branch
- If in detached HEAD state, stop and ask

### 3. Update both manifests with the helper script

```bash
python3 scripts/set_target_revision.py --current
python3 scripts/set_target_revision.py --main
python3 scripts/set_target_revision.py --branch feat/my-branch
python3 scripts/set_target_revision.py --current --dry-run
```

### 4. Review the result

```bash
git diff -- argocd/app-of-apps.yaml argocd/apps/values.yaml
```

Verify that both files point to the same branch.

### 5. Apply the switch to the cluster only when needed

```bash
oc apply -f argocd/app-of-apps.yaml
oc get application rhoai-platform-ops -n openshift-gitops
```

Only apply if the user explicitly asks for a live switch.

## Rollback

```bash
python3 scripts/set_target_revision.py --main
git diff -- argocd/app-of-apps.yaml argocd/apps/values.yaml
oc apply -f argocd/app-of-apps.yaml
```

## Guardrails

- Do not commit or push unless the user explicitly asks
- Do not change `repoURL`; this skill only switches branches
- If the manifests have unrelated edits, read them carefully before overwriting
