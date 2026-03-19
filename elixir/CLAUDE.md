# Symphony Elixir — Claude Code Guide

## Key Architecture

- `Linear.Issue` is the **universal normalized issue struct** for all tracker adapters (Linear, GitHub, Memory) — the module path is misleading, don't create adapter-specific issue structs.
- Runtime config flows: `WORKFLOW.md` → `Workflow` → `Config` → `Schema.parse/1`. `finalize_settings/1` auto-resolves `$ENV_VAR` references, falls back to well-known env vars (`GITHUB_TOKEN`, `GITHUB_ASSIGNEE`), and swaps the Linear default endpoint when `kind: github`.
- GitHub adapter uses REST for issues and GraphQL only for Projects v2 status. `ProjectClient` routes GraphQL through `Client.api_request/3`, so one HTTP seam covers both.
- `:persistent_term` caches project metadata (field IDs, option IDs) keyed by config tuple. Intentionally lock-free — concurrent cache misses duplicate the upstream call but converge on the same data.

## Credo / Linting

Credo runs as a **post-edit hook** with strict limits:
- Max cyclomatic complexity: **9**
- Max nesting depth: **2**
- Compile with `--warnings-as-errors`

Plan for this upfront. Large `cond` blocks and nested `with`/`case` will fail. Extract helper functions proactively. Pre-existing violations in `github/client.ex` are grandfathered.

## Test Patterns

- **HTTP mock seam**: `Application.get_env(:symphony_elixir, :github_request_fun)` — `fn method, url, {token, body} -> response end`. Covers both REST and GraphQL since ProjectClient uses `Client.api_request/3`.
- **Module injection**: `Application.get_env(:symphony_elixir, :github_client_module, Client)` and `:github_project_client_module`. Always restore in `on_exit`.
- **YAML generation**: Optional fields in test support must use conditional inclusion (`field && "  key: value"`). Emitting `null` overrides Ecto schema defaults.
- **WorkflowStore**: `force_reload()` is called automatically by `write_workflow_file!/2` — no need to call it manually in tests.

## GitHub Tracker: Labels vs Projects

Two `state_source` modes:
- `"labels"` (default): reads/writes state via `state/<StateName>` labels
- `"project"`: reads state from Projects v2 board Status field, writes via GraphQL mutation. No label writes. Still syncs GitHub open/closed state.

When `state_source: "project"`, `ensure_state_labels/0` is a no-op.
