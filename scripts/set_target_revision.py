#!/usr/bin/env python3
"""Update the Argo CD targetRevision in the repo manifests."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


FILES = (
    "argocd/app-of-apps.yaml",
    "argocd/apps/values.yaml",
)
TARGET_REVISION_RE = re.compile(r"^(?P<prefix>\s*targetRevision:\s*).+$", re.MULTILINE)


def get_repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def get_current_branch(repo_root: Path) -> str:
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )
    branch = result.stdout.strip()
    if not branch:
        raise ValueError("Unable to determine the current branch. Detached HEAD is not supported.")
    return branch


def resolve_target_branch(args: argparse.Namespace, repo_root: Path) -> str:
    if args.main:
        return "main"
    if args.branch:
        return args.branch

    branch = get_current_branch(repo_root)
    if branch == "main":
        raise ValueError("Current branch is already 'main'. Use --branch or keep --main for rollback.")
    return branch


def update_file(path: Path, branch: str, dry_run: bool) -> bool:
    original = path.read_text(encoding="utf-8")
    matches = list(TARGET_REVISION_RE.finditer(original))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one targetRevision in {path}, found {len(matches)}.")

    updated = TARGET_REVISION_RE.sub(lambda match: f"{match.group('prefix')}{branch}", original, count=1)
    changed = updated != original

    if changed and not dry_run:
        path.write_text(updated, encoding="utf-8")

    return changed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Switch Argo CD manifests between main and a feature branch."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--current",
        action="store_true",
        help="Use the current git branch. Fails if already on main.",
    )
    group.add_argument(
        "--main",
        action="store_true",
        help="Set the target revision back to main.",
    )
    group.add_argument(
        "--branch",
        help="Set an explicit branch name.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without writing files.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = get_repo_root()

    try:
        branch = resolve_target_branch(args, repo_root)
        print(f"Target revision: {branch}")
        for relative_path in FILES:
            path = repo_root / relative_path
            changed = update_file(path, branch, dry_run=args.dry_run)
            status = "would update" if args.dry_run and changed else "updated" if changed else "unchanged"
            print(f"- {relative_path}: {status}")
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
