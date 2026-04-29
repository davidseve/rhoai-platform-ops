---
description: "Create a new Architecture Decision Record (ADR). Documents context, options considered, and rationale."
user_invocable: true
---

# Create ADR

Create a new Architecture Decision Record in `docs/adr/`.

## Process

### 1. Determine Next ADR Number

Check `docs/adr/` for existing ADRs. The next number is the highest existing number + 1, zero-padded to 4 digits.

### 2. Gather Decision Details

If the user provided a topic, use that as context. Otherwise ask:

> **What architectural decision do you need to document?**
> **What context or constraints led to this decision? What options did you consider?**

### 3. Write the ADR

Create `docs/adr/NNNN-<kebab-case-title>.md`:

```markdown
# ADR-NNNN: <Title>

## Status
Accepted

## Context
<What motivated this decision? Include constraints and Red Hat documentation URLs.>

## Options Considered

### Option 1: <Name>
- **Pros:** ...
- **Cons:** ...

### Option 2: <Name>
- **Pros:** ...
- **Cons:** ...

## Decision
<What we chose and why>

## Consequences
### Positive
- ...
### Negative
- ...

## References
- <Red Hat documentation URLs>
- <Related ADRs>
```

Use `<!-- TODO: fill in -->` for incomplete sections.

### 4. Confirm

```
Created: docs/adr/NNNN-<title>.md
Decision: <one-line summary>
Status: Accepted
```

Remind the user to update `AGENTS.md` and `CLAUDE.md` if the decision affects project conventions.
