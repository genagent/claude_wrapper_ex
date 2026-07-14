# AGENTS.md

Guidance for AI coding agents working in this repository. For the full
module map and design rationale, see [CLAUDE.md](CLAUDE.md).

`claude_wrapper` is an Elixir wrapper for the Claude Code CLI, kept at
feature parity with the Rust crate
[`claude-wrapper`](https://github.com/joshrotenberg/claude-wrapper).

## Setup commands

- Elixir 1.18+ / OTP 27+.
- Install dependencies: `mix deps.get`.
- The only runtime dependencies are `jason` and `telemetry`. Do not add
  others without discussion.

## Build and test

Run the full pre-commit checklist before pushing:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
mix dialyzer
mix docs --warnings-as-errors
```

- `mix test` runs the unit suite (integration tests are excluded).
- `mix test --include integration` also runs tests that invoke the real
  `claude` binary and read real `~/.claude` data. They require `claude`
  installed, authenticated, and on `PATH`, so they are environment
  dependent and off by default.

## Code style

- Results are tagged tuples: `{:ok, value}` / `{:error, reason}`. Every
  error `reason` is a `%ClaudeWrapper.Error{}` exception -- match on its
  `:kind` field.
- Per-call options funnel through `Query.apply_opts/2`, the single place
  keyword options map to setters. Add new options there.
- `@moduledoc`, `@doc`, and `@spec` on every public function. Keep
  `mix credo --strict` clean (notably: max function nesting depth is 2 --
  extract private helpers; prefer `if` over a single-branch `cond`).
- No YAML dependency: the Agents/Skills frontmatter parsing is
  hand-rolled. Known scalar keys are typed; everything else is preserved
  in an `extra` map.

## Testing instructions

- Unit tests fake `claude` with `cat` for `DuplexSession`/`DuplexIEx`
  (NDJSON is injected via `Port.command/2`). Read-side modules use
  temp-dir fixtures cleaned with `on_exit`.
- Mark live tests with `@tag :integration` (or `@moduletag`); they are
  excluded from the default run.

## Commit and PR instructions

- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`,
  `refactor:`; `feat!:` or a `BREAKING CHANGE:` footer for breaking
  changes). Releases are cut and published to hex automatically by
  release-please from the commit history.
- Branch off `main`; never commit to `main` directly.
- CI must be green (format, compile with warnings-as-errors, credo
  `--strict`, dialyzer, tests, docs) before a PR is merged.

## Security

- This library shells out to the `claude` binary.
  `--dangerously-skip-permissions` is gated behind
  `ClaudeWrapper.DangerousClient`, which requires
  `CLAUDE_WRAPPER_ALLOW_DANGEROUS=1`.
- Settings files can contain secrets; use
  `ClaudeWrapper.Settings.redact_env_values/1` before logging or
  forwarding them.
