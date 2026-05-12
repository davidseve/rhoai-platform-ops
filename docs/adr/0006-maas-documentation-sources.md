# ADR-0006: MaaS Documentation Sources of Truth

## Status

Accepted

## Context

The MaaS module in this project implements
[Models-as-a-Service](https://github.com/opendatahub-io/models-as-a-service)
on top of Red Hat OpenShift AI (RHOAI). Because this is a **Red Hat product
installation**, the official Red Hat documentation carries the highest weight
for supportability, configuration, and operational guidance.

However, the upstream OpenDataHub MaaS project evolves faster than the product
docs -- CRDs, controller behavior, and recommended configurations change
between RHOAI releases (e.g., the transition from tiers to subscriptions in
3.4, documented in [ADR-0005](0005-maas-subscription-model.md)). The upstream
docs and repository provide depth that the product docs do not always cover
(CRD field reference, controller internals, migration guides).

We needed to establish which sources are authoritative, and in what order,
when making decisions about CRD usage, chart configuration, API contracts,
and troubleshooting.

## Options Considered

### Option 1: Rely on RHOAI product documentation only

- Pros: Official Red Hat support, versioned, stable, aligned with GA releases
- Cons: May lag behind on MaaS-specific CRDs (MaaSModelRef, MaaSSubscription,
  MaaSAuthPolicy) and controller internals; EA documentation may be incomplete

### Option 2: Use upstream MaaS documentation and repository only

- Pros: Most up-to-date, covers all CRDs and controller behavior, includes
  migration guides and API reference
- Cons: Community-maintained (not Red Hat supported), may include features
  not yet GA in RHOAI, may differ from the productized version

### Option 3: Use all three sources with clear precedence

- Pros: Combines Red Hat authority with upstream depth and source-code truth
- Cons: Requires judgement on which source takes precedence in conflicts

## Decision

Adopt Option 3: use all three sources with the following precedence.

### 1. Red Hat Official Documentation (PRIMARY)

**URL:** https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index

This is a Red Hat product installation. The official documentation is the
primary authority for:

- Supported configurations, GA vs. Tech Preview features
- Installation procedures and prerequisites
- Operator channels and upgrade paths
- Red Hat support scope and limitations
- Gateway, DSC, and platform-level configuration

When the product docs cover a topic, follow them. Defer to upstream only
when the product docs are silent or ambiguous.

### 2. Upstream MaaS Documentation (SECONDARY -- technical depth)

**URL:** https://opendatahub-io.github.io/models-as-a-service/latest/

Complements the product docs with:

- CRD field reference (MaaSModelRef, MaaSSubscription, MaaSAuthPolicy,
  ExternalModel, Tenant)
- Controller behavior, reconciliation logic, auto-created resources
- CRD annotations and their effect on the `/v1/models` API
- Installation and configuration details not yet in product docs
- Migration guides (e.g., tier-to-subscription)
- API reference (Swagger)

### 3. Upstream MaaS Git Repository (TERTIARY -- source of truth for code)

**URL:** https://github.com/opendatahub-io/models-as-a-service

The ultimate source of truth when docs disagree:

- Source code for CRDs, controllers, and kustomize manifests
- Pull requests for understanding bug fixes and feature changes
  (e.g., [PR #543](https://github.com/opendatahub-io/models-as-a-service/pull/543)
  for `groups_str` fix)
- Issues for tracking known problems
- Deploy scripts and sample manifests

### Precedence Rules

| Question | Primary Source |
|----------|---------------|
| Is feature X supported/GA? | Red Hat docs |
| Which operator channel to use? | Red Hat docs |
| What fields does CRD X accept? | Upstream MaaS docs → repo code |
| What does the controller auto-create? | Upstream MaaS docs → repo code |
| How to configure Gateway/DSC? | Red Hat docs → upstream MaaS docs |
| What annotations are available? | Upstream MaaS docs |
| Bug or unexpected behavior? | Upstream repo (issues/PRs) |
| Workaround for a known bug? | Upstream repo (PRs) → Red Hat KBs |

**Conflict resolution:** When Red Hat docs and upstream docs disagree on
behavior, verify against the actual code in the upstream repository. If a
feature exists in upstream but is not mentioned in Red Hat docs, treat it
as Tech Preview / unsupported until confirmed.

## Consequences

### Positive

- Red Hat product docs are respected as the primary authority, appropriate
  for a productized installation
- Upstream docs fill the gaps on CRD details and controller behavior
- PR references provide traceability for workarounds and expected fixes
- AI agents working on this repo have explicit, prioritized guidance on
  where to look

### Negative

- Red Hat docs for MaaS (RHOAI 3.4) are still maturing (EA2 phase) --
  some topics are only covered by upstream docs for now
- Must re-evaluate precedence when RHOAI 3.4 reaches GA and product docs
  become more complete
- Upstream repo may change between RHOAI releases; pin references to
  specific commits or PRs when documenting workarounds
