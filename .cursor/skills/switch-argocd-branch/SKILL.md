---
name: switch-argocd-branch
description: Switch Argo CD application target revisions between `main` and the current git branch by updating `argocd/app-of-apps.yaml` and `argocd/apps/values.yaml`. Use when the user asks to point ArgoCD apps to the current branch, switch back to `main`, or test a feature branch in-cluster.
---

# Switch ArgoCD Branch

Use this skill in `rhoai-platform-ops` when Argo CD must follow the current feature branch instead of `main`, or when switching back to `main`.

## What This Changes

Update both branch references together:

- `argocd/app-of-apps.yaml` for the root `rhoai-platform-ops` Application
- `argocd/apps/values.yaml` for the child Applications rendered by Helm

Updating only one of these files is incomplete.

## Workflow

Copy this checklist and track progress:

```text
ArgoCD branch switch
- [ ] Confirm target branch (`main` or current branch)
- [ ] Verify git branch and remote availability
- [ ] Update both Argo CD manifests
- [ ] Review the diff
- [ ] Apply to the cluster if the user wants the switch now
```

### 1. Confirm the target branch

- **Switch to working branch**: use the current git branch
- **Switch back**: use `main`

If the user asks for a specific branch name, use that explicitly instead of the current branch.

### 2. Check branch state

Run:

```bash
git branch --show-current
git status --short
git ls-remote --heads origin "$(git branch --show-current)"
```

Rules:

- If switching to a feature branch, warn the user if that branch is not pushed to `origin` yet. Argo CD cannot sync a branch that does not exist remotely.
- If the current branch is `main`, `--current` is a no-op for this workflow. Confirm whether the user really wants `main` or another branch.
- If git is in detached HEAD state, stop and ask the user how to proceed.

### 3. Update both manifests with the helper script

Use the script instead of editing the YAML by hand:

```bash
python3 .cursor/skills/switch-argocd-branch/scripts/set_target_revision.py --current
```

To switch back to `main`:

```bash
python3 .cursor/skills/switch-argocd-branch/scripts/set_target_revision.py --main
```

To set an explicit branch:

```bash
python3 .cursor/skills/switch-argocd-branch/scripts/set_target_revision.py --branch feat/my-branch
```

Optional dry-run:

```bash
python3 .cursor/skills/switch-argocd-branch/scripts/set_target_revision.py --current --dry-run
```

### 4. Review the result

Run:

```bash
git diff -- argocd/app-of-apps.yaml argocd/apps/values.yaml
```

Verify that both files point to the same branch.

### 5. Apply the switch to the cluster only when needed

If the user wants the live Argo CD root Application to switch immediately, apply the updated root manifest:

```bash
oc apply -f argocd/app-of-apps.yaml
oc get application rhoai-platform-ops -n openshift-gitops
```

Notes:

- Applying `argocd/app-of-apps.yaml` is what makes the root app start following the new branch right away.
- The child applications then reconcile from the branch set in `argocd/apps/values.yaml`.
- If the user only wants the repo changes prepared, stop after reviewing the diff and do not apply anything to the cluster.

## Rollback

To return everything to `main`:

```bash
python3 .cursor/skills/switch-argocd-branch/scripts/set_target_revision.py --main
git diff -- argocd/app-of-apps.yaml argocd/apps/values.yaml
oc apply -f argocd/app-of-apps.yaml
```

## Guardrails

- Do not commit or push unless the user explicitly asks.
- Do not change `repoURL` in this workflow; this skill only switches branches.
- If `argocd/app-of-apps.yaml` or `argocd/apps/values.yaml` already has unrelated edits, read them carefully before overwriting anything.
