---
description: "Commit, push to a branch, and create a pull request. Validates tests before committing, uses conventional commits."
user_invocable: true
---

# Push and PR

Commit, push to a branch, and open a pull request.

## Process

### Step 1 — Check Repo State

```bash
git status
git diff --stat
git log --oneline -5
```

If working tree is clean, stop.

### Step 2 — Run Tests

```bash
make lint
make test-all
```

- Lint fails → stop and fix
- Tests fail → warn and ask whether to continue or abort

### Step 3 — Create or Switch to Branch

If on `main`, create: `git checkout -b <type>/<short-description>`
Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

If already on a feature branch, stay on it.

### Step 4 — Stage and Commit

```bash
git add <files>
```

Do NOT stage: `.env`, credentials, `.venv/`, `__pycache__/`, `.pytest_cache/`

Conventional commits with HEREDOC:
```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <summary>

<body if needed>
EOF
)"
```

### Step 5 — Push Branch

```bash
git push -u origin HEAD
```

Never force-push without explicit permission.

### Step 6 — Create Pull Request

```bash
gh pr create --title "<type>(<scope>): <summary>" --body "$(cat <<'EOF'
## Summary
- <bullets covering ALL commits on the branch>

## Test plan
- [x] `make lint` passed
- [x] `make test-all` passed
EOF
)"
```

Use `git log main..HEAD` for full scope. Print PR URL when done.

## Edge Cases

- **Existing PR**: Check `gh pr list --head <branch>` first
- **No remote**: Stop and tell the user
- **No gh CLI**: Print URL for manual PR creation
