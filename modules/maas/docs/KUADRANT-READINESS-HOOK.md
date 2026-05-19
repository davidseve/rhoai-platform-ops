# Kuadrant Readiness Hook (Obsolete)

> **Superseded**: This hook (`kuadrant-readiness-hook.yaml`) was replaced by `authorino-tls-job.yaml` in RHOAI 3.4 GA. See [AUTHORINO-TLS.md](AUTHORINO-TLS.md) for the current documentation.

The original hook handled three tasks that are no longer needed in RHOAI 3.4:

1. **Kuadrant MissingDependency recovery** — No longer occurs in 3.4 (operator startup order fixed).
2. **Limitador/Envoy pod restarts** — No longer needed (controller handles WasmPlugin lifecycle).
3. **Authorino TLS setup** — Still required, now handled by `authorino-tls-job.yaml` with simplified RBAC (Roles instead of ClusterRoles).
