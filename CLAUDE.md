# claude_wrapper_ex

Elixir wrapper for the Claude Code CLI. Published on hex.pm as
[`claude_wrapper`](https://hex.pm/packages/claude_wrapper). It mirrors,
and is kept at feature parity with, the Rust crate
[`claude-wrapper`](https://github.com/joshrotenberg/claude-wrapper).

This file is the architecture and contributor guide. It also serves as
working context for AI coding agents (Claude Code and others) in this
repo; see also `AGENTS.md`.

## Architecture

Two first-class ways to drive `claude`, plus read-side introspection of
Claude Code's on-disk state, a typed command surface, and a single
canonical error type.

### Driving claude

```
ClaudeWrapper.DuplexSession   # Long-lived stream-json GenServer (headline)
ClaudeWrapper.DuplexIEx       # REPL helpers for DuplexSession
ClaudeWrapper.Conversation    # Turn-history/cost bookkeeping over a DuplexSession

ClaudeWrapper                 # Convenience API (query/2, stream/2, raw/2, version/0, ...)
ClaudeWrapper.Query           # Per-call query builder + execute/stream + apply_opts/2
ClaudeWrapper.Session         # Multi-turn continuity over per-call subprocesses
ClaudeWrapper.SessionServer   # GenServer wrapper for Session
ClaudeWrapper.IEx             # REPL helpers for one-shot/per-call mode
```

### Config, results, support

```
ClaudeWrapper.Config          # Shared client config (binary, working_dir, env, timeout)
ClaudeWrapper.Result          # Parsed result struct
ClaudeWrapper.StreamEvent     # One NDJSON event; partial_message/1 typed accessor
ClaudeWrapper.Error           # Canonical error exception (see "Error handling")
ClaudeWrapper.McpConfig       # Programmatic .mcp.json builder
ClaudeWrapper.Retry           # Retry policy with exponential backoff + jitter
ClaudeWrapper.Telemetry       # :telemetry spans for exec/stream/session
ClaudeWrapper.Budget          # Client-side USD budget tracker (GenServer)
ClaudeWrapper.ToolPattern     # Typed, validated tool-spec builder
ClaudeWrapper.CliVersion      # Parse/compare the claude CLI version
ClaudeWrapper.DangerousClient # Env-gated --dangerously-skip-permissions wrapper
ClaudeWrapper.Auth            # Env-based auth detection + failure classification
ClaudeWrapper.Test            # Drive a DuplexSession against an in-process double (network-free)
ClaudeWrapper.Bundled         # Opt-in bundled-binary resolve/install (cli_path: :bundled)
```

Binary resolution is opt-in: `Config.new(binary: :bundled)` resolves to
`priv/bin/claude` (pure); installing is explicit via `ClaudeWrapper.Bundled`
or the `mix claude_wrapper.install` / `.uninstall` / `.path` tasks. The
default stays PATH/`CLAUDE_CLI` discovery.

### DuplexSession transport adapter

```
ClaudeWrapper.DuplexSession.Adapter        # open/command/close transport seam
ClaudeWrapper.DuplexSession.Adapter.Port   # default: real claude subprocess over a Port
ClaudeWrapper.DuplexSession.Adapter.Test   # per-session controllable double (ClaudeWrapper.Test)
```

### Read-side introspection of `~/.claude`

```
ClaudeWrapper.History    # Session JSONL transcripts (projects / sessions / entries)
ClaudeWrapper.Settings   # The four settings.json layers (reported, not merged)
ClaudeWrapper.Agents     # Read/write agent definition .md files
ClaudeWrapper.Skills     # Read ~/.claude/skills/<stem>/SKILL.md
ClaudeWrapper.Jobs       # Read background-job state
ClaudeWrapper.Worktrees  # git worktree introspection
```

### Command surface

```
ClaudeWrapper.Command                # Behaviour for CLI commands
ClaudeWrapper.Commands.Auth          # auth login (email/mode/sso) / logout / status / setup-token
ClaudeWrapper.Commands.Agents        # list configured agents
ClaudeWrapper.Commands.Doctor        # claude doctor
ClaudeWrapper.Commands.Mcp           # mcp add / add-json / add-from-desktop / serve / login / logout / list / get / remove
ClaudeWrapper.Commands.Plugin        # plugin install/uninstall/enable/disable/update/validate/tag/details/prune
ClaudeWrapper.Commands.Marketplace   # marketplace add/remove/list/update
ClaudeWrapper.Commands.AutoMode      # auto-mode config / defaults / critique
ClaudeWrapper.Commands.Install       # claude install
ClaudeWrapper.Commands.Update        # claude update
ClaudeWrapper.Commands.Project       # project purge
ClaudeWrapper.Commands.Version       # claude --version
```

## DuplexSession is the headline feature

It holds **one** `claude` subprocess open across many turns using
`--input-format stream-json --output-format stream-json`. This is the
same protocol the official `@anthropic-ai/claude-agent-sdk` uses
internally and that `@agentclientprotocol/claude-agent-acp` relies on
for IDE integrations like Zed's agent panel.

Capabilities the per-call surface cannot offer:

- Live partial-token streaming (subscribers see `:stream_event` events;
  decode them with `StreamEvent.partial_message/1`)
- Mid-turn permission decisions via the `:on_permission` callback (or
  asynchronously via `respond_to_permission/3`)
- Clean mid-turn cancellation via `interrupt/1` (no SIGKILL)
- Amortized cold-start across many short turns

Health and bookkeeping: `alive?/1`, `exit_status/1`, and
`wait_for_exit/2` give non-consuming liveness; wrap a session in
`ClaudeWrapper.Conversation` for turn history and cumulative cost.

## Per-call surface remains useful

`Query.execute/2`, `Session.send/3`, and the `IEx` REPL helpers are not
deprecated. They are the right fit for short-lived hosts (escripts, mix
tasks, batch jobs, anything that runs and exits) where a long-lived
GenServer is overkill.

## Read-side introspection

The `History`, `Settings`, `Agents`, `Skills`, `Jobs`, and `Worktrees`
modules read Claude Code's on-disk state under `~/.claude` (and git
worktrees) without driving the CLI. They parse liberally -- malformed
lines/files are skipped rather than failing the whole read -- and return
typed structs. `History.project_slug/1` derives Claude Code's
project-directory slug (canonicalize, then encode `/` and `.` as `-`),
and `ProjectSummary.decoded_path` decodes it back by anchoring on the
real filesystem to disambiguate literal hyphens.

## Error handling

Every operational failure is returned as
`{:error, %ClaudeWrapper.Error{kind: ...}}` and can also be raised (it
is a proper exception). Branch on the `:kind` atom; details live in
`:reason` plus the dedicated `:exit_code` / `:stdout` / `:stderr`
fields. The `kind` set mirrors the Rust crate's `Error` enum
(`:command_failed`, `:io`, `:timeout`, `:json`, `:max_turns_exceeded`,
`:version_mismatch`, `:budget_exceeded`, `:auth`, `:duplex_closed`,
`:turn_in_flight`, `:not_found`, ...).

One behavior worth knowing: hitting `--max-turns` returns
`{:error, %Error{kind: :max_turns_exceeded}}` rather than a successful
result flagged as an error.

## Design decisions

- **stdlib only for process management**: a Port with manual `\n` line
  splitting (we deliberately avoid `:line` mode because tool results can
  exceed any fixed line cap). `System.cmd` for one-shots. No external
  deps beyond `jason` and `telemetry`.
- **Structs over builders**: `Query` is a struct with pipe-friendly
  setter functions, plus `Query.apply_opts/2` to apply a keyword list.
- **Config is separate from Query**: `Config` holds shared/reusable
  settings (binary path, working dir, env). `Query` holds per-invocation
  options. Mirrors the Rust crate's `Claude` (shared) vs `QueryCommand`
  (per-call) split.
- **Single source of truth for opts -> setters**: `Query.apply_opts/2`
  is the one place keyword opts get translated into setter calls;
  `ClaudeWrapper.query/2`, `stream/2`, and `Session.send/3` all delegate
  to it.
- **One canonical error type**: `ClaudeWrapper.Error`, rather than
  per-call ad-hoc tuples (see "Error handling").
- **No YAML dependency**: the `Agents`/`Skills` frontmatter parsers are
  hand-rolled. Known scalar keys are typed; everything else is preserved
  verbatim in an `extra` map.

## Rust reference

The Rust crate at `../claude-wrapper` is the reference; the two are kept
at feature parity. Key mappings:

- `Claude` / `ClaudeBuilder` -> `ClaudeWrapper.Config` / `Config.new/1`
- `QueryCommand` -> `ClaudeWrapper.Query`; `QueryResult` -> `Result`
- `StreamEvent` -> `ClaudeWrapper.StreamEvent` (+ `partial_message/1`)
- `Error` enum -> `ClaudeWrapper.Error` (`:kind` mirrors the variants)
- `DuplexSession` / `Conversation` -> same names here
- `HistoryRoot` -> `History`; `SettingsLoader` -> `Settings`;
  `AgentsRoot` -> `Agents`; `SkillsRoot` -> `Skills`; `JobsRoot` ->
  `Jobs`; `WorktreeRoot` -> `Worktrees`
- `BudgetTracker` -> `Budget`; `ToolPattern` -> `ToolPattern`;
  `CliVersion` -> `CliVersion`; `DangerousClient` -> `DangerousClient`;
  `auth::detect` / `classify_failure` -> `Auth`
- `PermissionMode` -> `:default | :accept_edits | :bypass_permissions | :dont_ask | :plan | :auto`
- `OutputFormat` -> `:text | :json | :stream_json`
- `Effort` -> `:low | :medium | :high | :xhigh | :max`
- `ClaudeCommand` trait -> `ClaudeWrapper.Command` behaviour

## Multi-agent coordination has moved out

Workshop and its MCP server were extracted to the standalone
`agent_workshop` hex package. It is backend-agnostic and can drive
Claude, Codex, or any agent that implements its `Backend` behaviour.

## Testing

```bash
mix test                        # Unit tests (excludes integration)
mix test --include integration  # All tests, including those that hit the real CLI
mix test --only integration     # Only integration tests
```

Some unit tests use `cat` as a fake `claude` for `DuplexSession` and
`DuplexIEx` -- we inject NDJSON via `Port.command/2` and observe the
GenServer's dispatch behavior. New session tests prefer
`ClaudeWrapper.Test` (the `Adapter.Test` transport double): each
`start_session/1` gets its own controllable stub with no shared state, so
it is `async`-safe and is also the supported way for downstream users to
test code that drives `claude_wrapper`. Integration tests run against the
real `claude` binary and against real `~/.claude` data (for the read-side
modules), so they are environment-dependent and excluded by default.

Pre-commit checklist: `mix format`, `mix compile --warnings-as-errors`,
`mix credo --strict`, `mix test`, `mix dialyzer`.
