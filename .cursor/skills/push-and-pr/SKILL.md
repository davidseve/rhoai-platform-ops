---
name: push-and-pr
description: >-
  Push changes to a new branch and create a pull request. Creates the branch
  if it doesn't exist, commits all changes, pushes, and opens a PR with a
  generated summary. Use when the user says "push", "create PR", "pull request",
  "sube los cambios", "abre un PR", or similar.
---

# Push and PR

Commit, push to a branch, and open a pull request.

## Process

```
- [ ] Step 1: Check repo state
- [ ] Step 2: Run tests (make lint + make test-all)
- [ ] Step 3: Create or switch to branch
- [ ] Step 4: Stage and commit
- [ ] Step 5: Push branch
- [ ] Step 6: Create pull request
```

### Step 1 -- Check Repo State

```bash
git status
git diff --stat
git log --oneline -5
```

Verify there are actual changes to commit. If working tree is clean, tell the
user and stop.

Identify which repo has changes (the workspace may have multiple repos). Only
operate on repos with uncommitted changes.

### Step 2 -- Run Tests

Run validation and tests before committing:

```bash
make lint
make test-all
```

- If **lint fails**: stop and fix the issues before continuing. Do not commit broken
  code.
- If **tests fail**: warn the user with the failure output and ask whether to continue
  or abort. Some changes (docs, skills, CI config) may not need passing cluster tests.
- If both pass, proceed to branch creation and commit.

### Step 3 -- Create or Switch to Branch

Check the current branch:

```bash
git branch --show-current
```

**If already on a feature branch** (anything other than `main`): stay on it.

**If on `main`**: create a new branch. Derive the name from the changes:

```bash
git checkout -b <branch-name>
```

Branch naming: `<type>/<short-description>` where type is one of:
`feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

Examples: `feat/add-observability-module`, `fix/cleanup-stuck-helm-releases`,
`chore/update-bootstrap-skill`.

### Step 4 -- Stage and Commit

Review changes and stage relevant files:

```bash
git add <files>
```

**Do NOT stage:**
- `.env`, credentials, secrets
- Large generated files, binaries
- Temporary/cache files (`.venv/`, `__pycache__/`, `.pytest_cache/`)

Write a concise commit message focused on the "why". Follow conventional commits
style. Use a HEREDOC for multi-line messages:

```bash
git commit -m "$(cat <<'EOF'
<type>(<scope>): <summary>

<body if needed>
EOF
)"
```

If there are logically separate groups of changes, create multiple commits.

### Step 5 -- Push Branch

```bash
git push -u origin HEAD
```

If the remote rejects the push (e.g., branch already exists with different
history), inform the user -- never force-push without explicit permission.

### Step 6 -- Create Pull Request

Use `gh pr create` with a structured body:

```bash
gh pr create --title "<type>(<scope>): <summary>" --body "$(cat <<'EOF'
## Summary
- <bullet 1>
- <bullet 2>

## Test plan
- [x] `make lint` passed
- [x] `make test-all` passed
EOF
)"
```

The "Test plan" section must reflect the actual results from Step 2. Use `[x]` for
checks that passed and `[ ]` for any that were skipped (with a note explaining why).

The PR summary should cover ALL commits on the branch (not just the latest).
Analyze `git log main..HEAD` to capture the full scope of changes.

After creation, print the PR URL so the user can see it.

## Edge Cases

- **Multiple repos in workspace**: Only operate on the repo with changes.
  Confirm with the user if multiple repos have changes.
- **Existing PR for branch**: Check with `gh pr list --head <branch>` first.
  If a PR already exists, push the new commits and inform the user instead of
  creating a duplicate PR.
- **No remote configured**: Stop and tell the user.
- **No `gh` CLI**: Fall back to printing the URL the user can use to create
  the PR manually in the browser.
