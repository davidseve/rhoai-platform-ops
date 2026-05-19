# ADR-0007: Unified MaaS Access Groups

## Status

Accepted

## Context

MaaSAuthPolicy and MaaSSubscription both require a list of Kubernetes groups:

- **MaaSAuthPolicy** (`spec.subjects.groups`): controls who can access the model (authentication gate).
- **MaaSSubscription** (`spec.owner.groups`): controls rate limiting per tier for those groups.

The auth check happens first — if a group is in `owner` but not in `subjects`, users in that group receive a 403 and never reach the rate limiter. Both lists **must** be consistent, but defining them separately in `values.yaml` created a risk of silent misconfiguration.

## Options Considered

### Option 1: Separate lists (status quo)

`authPolicy.subjects.groups` and `subscription.tiers.*.groups` defined independently.

- Pros: explicit, each CRD has its own values section.
- Cons: duplication, risk of inconsistency (group in owner but not in subjects → 403).

### Option 2: Unified section `access`

Replace both sections with a single `access.tiers` block.

- Pros: single source of truth, clean values structure.
- Cons: breaking change to values schema, harder to map values to CRD fields.

### Option 3: Derive subjects from tiers

Keep `subscription.tiers` as the single source for groups. The MaaSAuthPolicy template extracts unique groups from all tiers automatically.

- Pros: single source of truth, minimal values change, direct mapping to CRD remains clear.
- Cons: implicit relationship between template files (auth-policy reads subscription values).

## Decision

**Option 3: Derive subjects from tiers.** The MaaSAuthPolicy template iterates over `subscription.tiers`, extracts all group names, deduplicates them, and emits them as `subjects.groups`. Individual users (`authPolicy.subjects.users`) remain as a separate manual list since users are not tier-scoped.

This guarantees that every group with a rate-limiting tier automatically has access to the model — it is impossible to have a group in `owner` without it also being in `subjects`.

## Consequences

- **Positive:** eliminates misconfiguration risk, reduces values duplication, one place to manage groups.
- **Positive:** `authPolicy.subjects.users` remains available for granting access to individual users without a tier.
- **Negative:** the relationship between auth-policy and subscription templates is implicit — a developer reading `maas-auth-policy.yaml` must understand that groups come from `subscription.tiers`.
