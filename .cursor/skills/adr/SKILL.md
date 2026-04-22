---
description: Create a new Architecture Decision Record (ADR). Documents the context, options considered, and rationale for architectural decisions.
user_invocable: true
---

# Create ADR

Create a new Architecture Decision Record in `docs/adr/`.

## Process

### 1. Determine Next ADR Number

Check `docs/adr/` for existing ADRs. The next number is the highest existing number + 1, zero-padded to 4 digits (e.g., `0001`, `0002`). If `docs/adr/` doesn't exist, create it and start at `0001`.

### 2. Gather Decision Details

If the user provided a topic (e.g., "adr: use Grafana Operator for dashboards"), use that as context. Otherwise ask:

> **What architectural decision do you need to document?**

Then ask:

> **What context or constraints led to this decision? What options did you consider?**

### 3. Write the ADR

Create `docs/adr/NNNN-<kebab-case-title>.md`:

```markdown
# ADR-NNNN: <Title>

## Status

Accepted

## Context

<What is the issue or question that motivates this decision? Include constraints, requirements, and forces at play. Reference Red Hat documentation URLs where applicable.>

## Options Considered

### Option 1: <Name>
- **Pros:** ...
- **Cons:** ...

### Option 2: <Name>
- **Pros:** ...
- **Cons:** ...

### Option 3: <Name> (if applicable)
- **Pros:** ...
- **Cons:** ...

## Decision

<What is the change we are making? State the decision clearly.>

## Consequences

### Positive
- ...

### Negative
- ...

### Neutral
- ...

## References

- <Red Hat documentation URLs>
- <Related ADRs>
```

Fill in as much as possible from the user's input. For sections where information is incomplete, add `<!-- TODO: fill in -->` markers.

### 4. Confirm

Show the user the file path and a summary:

```
Created: docs/adr/NNNN-<title>.md
Decision: <one-line summary>
Status: Accepted

Review the ADR and update any TODO sections.
```

Also remind them to reference this ADR in `AGENTS.md` if it affects technology choices or project conventions.
