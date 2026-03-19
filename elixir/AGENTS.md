# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls issue trackers (Linear, GitHub), creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
  - `Config.finalize_settings/1` auto-resolves `$ENV_VAR` references and falls back to well-known env vars (`GITHUB_TOKEN`, `GITHUB_ASSIGNEE`, `LINEAR_API_KEY`).
- `Linear.Issue` is the **shared normalized issue struct** for all adapters (Linear, GitHub, Memory) despite the module path.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## GitHub Tracker

The GitHub adapter supports two state source modes:
- `state_source: "labels"` (default) — state via `state/<Name>` labels on issues
- `state_source: "project"` — state from a Projects v2 board Status field (GraphQL). No label writes in this mode.

`ProjectClient` routes GraphQL through `Client.api_request/3`, so the same HTTP mock seam (`Application.get_env(:symphony_elixir, :github_request_fun)`) covers both REST and GraphQL in tests. Module-level test seams: `:github_client_module`, `:github_project_client_module`.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
