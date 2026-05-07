# ADR-0005: MaaS Subscription Model (RHOAI 3.4)

## Status

Accepted (pending RHOAI 3.4 GA validation)

## Context

RHOAI 3.3 required manual governance: a PostSync hook patched the AuthPolicy
to inject tier identity, and per-tier RateLimitPolicy/TokenRateLimitPolicy
were managed via Helm. This worked but fought the operator at every sync.

RHOAI 3.4 introduces the `maas-controller` with a subscription-based model:
`MaaSModelRef`, `MaaSSubscription`, and automatic TokenRateLimitPolicy
generation. We evaluated this in 3.4 EA2 to decide whether to adopt it.

## Options Considered

### Option 1: Keep the tier model with custom AuthPolicy

- Pros: Known, tested, all rate limit tests pass
- Cons: Requires PostSync hook (fragile), fights the operator, `auth.identity.tier`
  not populated by KubernetesTokenReview in 3.4, fundamentally incompatible
  with 3.4 auth flow

### Option 2: Adopt MaaSSubscription model

- Pros: Aligns with RHOAI 3.4 direction, eliminates PostSync hooks,
  controller manages rate limits automatically, group-based access control
- Cons: EA2 has a bug where `groups_str` is not populated
  ([PR #543](https://github.com/opendatahub-io/models-as-a-service/pull/543)
  fixes this for GA), models must be in `models-as-a-service` namespace

## Decision

Adopt Option 2: MaaSSubscription model.

Changes made:

1. **Model namespace**: `maas-models` -> `models-as-a-service` (required by
   `maas-controller` -- MaaSModelRef looks up LLMInferenceService in same namespace)
2. **Per-tier rate limits**: Disabled (`rateLimiting.enabled: false`).
   MaaSSubscription creates TokenRateLimitPolicy per model automatically.
3. **RBAC**: Subjects changed from tier-specific service account groups to
   `system:authenticated`. KubernetesTokenReview uses the user's own token.
4. **PostSync hooks**: Both disabled (`cleanupAuthn`, `kuadrantReadiness`).
   `opendatahub.io/managed: "false"` annotation works in 3.4.
5. **Gateway**: `models-as-a-service` added to `allowedRoutes` (hardcoded,
   always needed for maas-controller HTTPRoutes).

## Consequences

### Positive

- No more PostSync hooks fighting the operator
- Rate limits managed declaratively via MaaSSubscription CRs
- Aligns with RHOAI's intended architecture
- Simpler GitOps: fewer resources to manage in Helm charts

### Negative

- Models must be in `models-as-a-service` namespace (controller limitation --
  MaaSModelRef CRD has no namespace field in `modelRef`)
- Request-level rate limiting not available (subscriptions only create
  TokenRateLimitPolicy, not RateLimitPolicy)
- EA2 token rate limits don't fire due to `groups_str` bug -- fixed in
  [PR #543](https://github.com/opendatahub-io/models-as-a-service/pull/543),
  expected in GA

### TODO for RHOAI 3.4 GA

- [ ] Verify token rate limits fire after `groups_str` fix (PR #543)
- [ ] Remove `xfail` markers from token rate limit tests
- [ ] Evaluate if `rateLimiting.enabled: true` is needed for request-level limits
- [ ] Check if MaaSModelRef gains a namespace field (cross-namespace references)
- [ ] Update operator channel from `beta` to `fast-3.x` (or GA channel)
- [ ] Update Chart.yaml `appVersion` from `3.4-ea2` to GA version
- [ ] Clean up old tier-specific templates if confirmed unnecessary
