# ClaudeWrapper

[![CI](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/claude_wrapper.svg)](https://hex.pm/packages/claude_wrapper)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/claude_wrapper)
[![License](https://img.shields.io/hexpm/l/claude_wrapper.svg)](https://github.com/genagent/claude_wrapper_ex/blob/main/LICENSE)

Drive the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) from Elixir: typed results and errors, streaming, tool-permission callbacks, and long-lived sessions — over the same `claude` binary you already run in a terminal.

`claude_wrapper` owns exactly the seam between Elixir and the `claude` process: spawning it, framing its NDJSON, and turning its output into typed `%ClaudeWrapper.Result{}` / `%ClaudeWrapper.Error{}`. It takes no position on what you do with a result. It offers **two ways to drive `claude`**, and you pick by the lifecycle of your host:

- **One-shot** (`ClaudeWrapper.query/2`, `Query`, `Session`) — a fresh subprocess per turn, simple request/response. The fit for `mix` tasks, escripts, batch jobs, and anything that runs and exits.
- **Long-lived** (`ClaudeWrapper.DuplexSession`) — a `GenServer` holding **one** `claude` subprocess open across a whole conversation: streams partial tokens, interrupts mid-turn, and routes tool-permission prompts back to your code. The fit for chat UIs, agent runtimes, and Phoenix-backed interfaces.

The long-lived mode speaks the same duplex protocol the official `@anthropic-ai/claude-agent-sdk` uses internally and that the `@agentclientprotocol/claude-agent-acp` bridge relies on for IDE integrations like Zed's agent panel — so an OTP host can use `claude` the way an IDE backend does.

## Installation

```elixir
def deps do
  [
    {:claude_wrapper, "~> 0.14"}
  ]
end
```

Requires the `claude` CLI installed and on your `PATH` (or set `CLAUDE_CLI` to its path). Run `claude doctor` — or, from Elixir, `ClaudeWrapper.doctor/0` — before your first real call.

## Quick start

```elixir
{:ok, result} = ClaudeWrapper.query("Explain this error: ...")
result.result       # the text
result.cost_usd     # spend for the call
```

Everything else is a variation on this: more control over the flags (`Query`), continuity across turns (`Session` / `DuplexSession`), streaming, or reading Claude Code's own on-disk state.

## Driving claude

### One-shot query and stream

For short-lived consumers, `query/2` runs a fresh subprocess and returns the full result; `stream/2` yields `%StreamEvent{}`s as they arrive. Both accept the same options (see [Building the call](#building-the-call)).

```elixir
{:ok, result} =
  ClaudeWrapper.query("Fix the bug in lib/foo.ex",
    model: "sonnet",
    working_dir: "/path/to/project",
    max_turns: 5,
    permission_mode: :bypass_permissions
  )

ClaudeWrapper.stream("Implement the feature in issue #42", working_dir: ".")
|> Stream.each(fn event -> IO.inspect(event.type) end)
|> Stream.run()
```

### Multi-turn without a process (`Session`)

`ClaudeWrapper.Session` threads `--resume <session_id>` across one-shot calls, so you get multi-turn continuity without holding a subprocess open — a struct-passing API, ideal outside an OTP host or when turns are far apart in wall time.

```elixir
session = ClaudeWrapper.Session.new(config, model: "sonnet")
{:ok, session, r1} = ClaudeWrapper.Session.send(session, "What files are here?")
{:ok, session, r2} = ClaudeWrapper.Session.send(session, "Add tests for lib/foo.ex")
```

`ClaudeWrapper.SessionServer` wraps this in a supervised GenServer when you want a process around the per-call flow but not live token streaming.

### Long-lived sessions (`DuplexSession`)

Holds one `claude` subprocess open across many turns; subscribers see assistant messages, partial token deltas, and tool-call results live.

```elixir
config = ClaudeWrapper.Config.new(working_dir: ".")
{:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config)
:ok = ClaudeWrapper.DuplexSession.subscribe(pid)

# Resolves when the CLI emits its `result` event; the inbox streamed the turn.
{:ok, result} = ClaudeWrapper.DuplexSession.send(pid, "Explain this codebase.")

# Inbox: {:claude, {:system_init, id}} | {:assistant, _} | {:stream_event, _}
#        | {:user, _}  (tool results) | {:result, %ClaudeWrapper.Result{}}

ClaudeWrapper.DuplexSession.interrupt(pid)   # cancel an in-flight turn cleanly
ClaudeWrapper.DuplexSession.close(pid)        # end the session
```

**Configure it with a `Query`.** Pass a `%Query{}` for the session's spawn-time knobs (model, system prompt, permission mode, tool lists, mcp config, ...); its prompt and transport flags are ignored (the session owns stream-json and takes prompts per turn).

```elixir
query = ClaudeWrapper.Query.new("") |> ClaudeWrapper.Query.model("sonnet") |> ClaudeWrapper.Query.allowed_tool("Read")
{:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config, query: query)
```

**Permission callback.** When the CLI wants a tool, it routes the request through your `:on_permission` callback — answer synchronously, or return `:defer` and answer later via `respond_to_permission/3` (for human-in-the-loop UIs).

```elixir
on_permission = fn tool_name, _input ->
  if tool_name == "Bash", do: {:deny, "no shell here"}, else: :allow
end

{:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config, on_permission: on_permission)
```

**Supervise it.** Each session owns one Port; pair it with a `DynamicSupervisor` for per-conversation isolation, named registration, and OTP restart semantics. See `ClaudeWrapper.DuplexSession` for the full API and message vocabulary.

### REPL helpers

For interactive exploration, two IEx helper modules stream tokens to stdout:

```elixir
iex> import ClaudeWrapper.DuplexIEx      # one long-lived session in the process dictionary
iex> start(working_dir: ".")
iex> say("Explain the README briefly.")   # ...streams live...

iex> import ClaudeWrapper.IEx            # per-call one-shot mode
iex> chat("explain this codebase", working_dir: ".")
iex> cost()
```

## Building the call

`ClaudeWrapper.Query` is the builder for the full CLI flag surface; `Query.apply_opts/2` takes a keyword list of any setter, and `query/2` / `stream/2` / `Session.send/3` all delegate to it, so the same options work everywhere.

```elixir
alias ClaudeWrapper.{Config, Query}

Query.new("Fix the tests")
|> Query.model("sonnet")
|> Query.max_turns(10)
|> Query.permission_mode(:bypass_permissions)
|> Query.allowed_tool("Read")
|> Query.execute(Config.new(working_dir: "/path/to/project"))
```

Supporting builders: `ClaudeWrapper.Prompt` (composable prompts with deferred file/git expansion), `ClaudeWrapper.McpConfig` (programmatic `.mcp.json`), and `ClaudeWrapper.ToolPattern` (typed, validated tool specs).

```elixir
ClaudeWrapper.McpConfig.new()
|> ClaudeWrapper.McpConfig.add_stdio("my-server", "npx", ["-y", "my-mcp-server"], env: %{"API_KEY" => "sk-..."})
|> ClaudeWrapper.McpConfig.write!(".mcp.json")
```

## Operational concerns

### Error handling

Every operational failure is `{:error, %ClaudeWrapper.Error{}}` — a raisable exception you match on by `:kind`, with details in `:reason` / `:exit_code` / `:stdout` / `:stderr`:

```elixir
case ClaudeWrapper.query("...", max_turns: 1) do
  {:ok, result} -> result
  {:error, %ClaudeWrapper.Error{kind: :max_turns_exceeded}} -> :hit_limit
  {:error, %ClaudeWrapper.Error{kind: kind}} -> {:failed, kind}
end
```

The CLI's own rail-stop caps are typed, recoverable errors — distinct from a genuine failure. `:max_turns_exceeded` (`--max-turns`) and `:max_budget_exceeded` (`--max-budget-usd`, separate from the client-side `:budget_exceeded` of `ClaudeWrapper.Budget`) each carry `reason: %{cap:, cost_usd:, num_turns:, session_id:}`, so a capped run can be resumed:

```elixir
{:error, %ClaudeWrapper.Error{kind: :max_budget_exceeded, reason: %{session_id: sid}}} = ...
# resume with Query.resume(sid) / Session
```

### Leak-free execution (opt-in)

By default a timeout, halted stream, closed session, or BEAM death closes the Erlang port or shuts down a `Task` — which closes the pipes but sends **no signal** to the OS process, so `claude` and every stdio MCP server it spawned can keep running (see [#185](https://github.com/genagent/claude_wrapper_ex/issues/185)). Add [`forcola`](https://hex.pm/packages/forcola) and select its implementations to run every invocation under a process-group kill (SIGTERM then SIGKILL on timeout/halt/close/BEAM-death):

```elixir
# mix.exs:  {:forcola, "~> 0.3"}
config :claude_wrapper,
  runner: ClaudeWrapper.Runner.Forcola,                        # one-shot + streaming
  duplex_adapter: ClaudeWrapper.DuplexSession.Adapter.Forcola  # DuplexSession
```

Both are opt-in and additive (they compile only when `forcola` is present); POSIX-only.

### Retry, telemetry, budget

- **`ClaudeWrapper.Retry`** — exponential backoff around a `Query`. The default retries timeouts, plain non-zero exits, and rate limits; other auth failures and rail stops are not retried.

  ```elixir
  ClaudeWrapper.Retry.execute(query, config, max_retries: 3, base_delay_ms: 1_000)
  ```

- **`ClaudeWrapper.Telemetry`** — `:telemetry.span/3`-shaped events (`:start` / `:stop` / `:exception`) around every exec path, so one handler observes the whole lifecycle. `:stop` metadata carries `:cost_usd`, `:exit_code`, `:duration`.

  | Event | Emitted by |
  |---|---|
  | `[:claude_wrapper, :exec, _]` | `query/2` / `Query.execute/2` |
  | `[:claude_wrapper, :stream, _]` | `stream/2` / `Query.stream/2` |
  | `[:claude_wrapper, :session, :turn, _]` | `Session.send/3` |
  | `[:claude_wrapper, :duplex, :session, _]` | `DuplexSession` process lifetime |
  | `[:claude_wrapper, :duplex, :turn, _]` | `DuplexSession.send/3` |

- **`ClaudeWrapper.Budget`** — a client-side USD budget tracker for multi-turn loops.

### Testing

Drive a `DuplexSession` against an in-process double (no network, no `claude`) with `ClaudeWrapper.Test` and `ClaudeWrapper.DuplexSession.Adapter.Test`.

## Reading `~/.claude` state

Beyond driving `claude`, the read-side modules introspect Claude Code's on-disk state — useful for dashboards, session pickers, and agent tooling. All parse liberally and return typed structs:

```elixir
{:ok, history} = ClaudeWrapper.History.home()
{:ok, sessions} = ClaudeWrapper.History.sessions_for_path(history, File.cwd!())
{:ok, settings} = ClaudeWrapper.Settings.load(project_root: File.cwd!())
```

`History`, `Settings`, `Agents`, `Skills`, `Jobs`, and `Worktrees` cover session transcripts, the settings layers, agent-definition files, skills, background jobs, and git worktrees.

## CLI subcommands & the raw escape hatch

Typed wrappers for the `claude` subcommands live under `ClaudeWrapper.Commands.*` (auth, mcp, plugin, marketplace, agents, doctor, version, …):

```elixir
{:ok, plugins} = ClaudeWrapper.Commands.Plugin.list(config)
{:ok, _} = ClaudeWrapper.Commands.Marketplace.add(config, "https://github.com/org/marketplace")
```

For anything not yet wrapped, `ClaudeWrapper.raw(["config", "list"])` runs an arbitrary subcommand through the configured runner.

### Bundled binary (opt-in)

Instead of a `PATH` install, `claude_wrapper` can resolve, install, and version-floor a `claude` binary under its own `priv/bin/`:

```elixir
config = ClaudeWrapper.Config.new(binary: :bundled)   # pure resolution; no network
```

```bash
mix claude_wrapper.install    # install/update the bundled binary
mix claude_wrapper.uninstall  # remove it
mix claude_wrapper.path       # print its path and install state
```

The `PATH` / `CLAUDE_CLI` default is unchanged for everyone else. See `ClaudeWrapper.Bundled`.

## Module reference

**Long-lived sessions (the headline feature)**

| Module | Description |
|---|---|
| `ClaudeWrapper.DuplexSession` | Long-lived stream-json session over a single `claude` subprocess |
| `ClaudeWrapper.DuplexIEx` | REPL helpers for `DuplexSession` |
| `ClaudeWrapper.Conversation` | Turn-history/cost bookkeeping over a `DuplexSession` |

**One-shot / per-call**

| Module | Description |
|---|---|
| `ClaudeWrapper` | Convenience API (`query/2`, `stream/2`, `version/0`, `auth_status/0`, `doctor/0`, `raw/2`) |
| `ClaudeWrapper.Query` | Query builder + execute/stream |
| `ClaudeWrapper.Session` | Multi-turn continuity over per-call subprocesses |
| `ClaudeWrapper.SessionServer` | Supervised wrapper for `Session` |
| `ClaudeWrapper.IEx` | REPL helpers for one-shot/per-call mode |

**Prompt building & structured output**

| Module | Description |
|---|---|
| `ClaudeWrapper.Prompt` | Composable prompt builder with deferred file/git expansion |
| `ClaudeWrapper.Stream` | Lazy `Stream` combinators over a `DuplexSession` turn |
| `ClaudeWrapper.Structured` | Typed structured-output tasks |

**Subprocess execution & transport**

| Module | Description |
|---|---|
| `ClaudeWrapper.Runner` | Behaviour selecting how one-shot/streaming subprocesses run |
| `ClaudeWrapper.Runner.Port` | Default: `System.cmd` + `/bin/sh` streaming port |
| `ClaudeWrapper.Runner.Forcola` | Opt-in leak-free runner (process-group kill); needs `forcola` |
| `ClaudeWrapper.DuplexSession.Adapter` | Transport seam for `DuplexSession` |
| `ClaudeWrapper.DuplexSession.Adapter.Port` | Default adapter: real `claude` subprocess over a Port |
| `ClaudeWrapper.DuplexSession.Adapter.Forcola` | Opt-in leak-free adapter; needs `forcola` |
| `ClaudeWrapper.DuplexSession.Adapter.Test` | Controllable in-process test double |

**Shared infrastructure**

| Module | Description |
|---|---|
| `ClaudeWrapper.Config` | Shared client config (binary, working_dir, env, timeout) |
| `ClaudeWrapper.Result` | Parsed result struct |
| `ClaudeWrapper.Error` | Canonical error exception (match on `:kind`) |
| `ClaudeWrapper.StreamEvent` | NDJSON streaming event (`partial_message/1`) |
| `ClaudeWrapper.McpConfig` | `.mcp.json` builder |
| `ClaudeWrapper.Retry` | Exponential backoff retry |
| `ClaudeWrapper.Telemetry` | `:telemetry` spans for exec/stream/session/duplex |
| `ClaudeWrapper.Budget` | Client-side USD budget tracker |
| `ClaudeWrapper.ToolPattern` | Typed, validated tool-spec builder |
| `ClaudeWrapper.CliVersion` | Parse/compare the CLI version |
| `ClaudeWrapper.DangerousClient` | Env-gated `--dangerously-skip-permissions` |
| `ClaudeWrapper.Auth` | Env auth detection + failure classification |
| `ClaudeWrapper.Test` | Drive a `DuplexSession` against an in-process double (network-free) |
| `ClaudeWrapper.Bundled` | Opt-in bundled-binary resolution |

**Reading `~/.claude` state**

| Module | Description |
|---|---|
| `ClaudeWrapper.History` | Session JSONL transcripts (projects/sessions/entries) |
| `ClaudeWrapper.Settings` | The four `settings.json` layers |
| `ClaudeWrapper.Agents` | Read/write agent definition files |
| `ClaudeWrapper.Skills` | Read `~/.claude/skills` |
| `ClaudeWrapper.Jobs` | Read background-job state |
| `ClaudeWrapper.Worktrees` | git worktree introspection |

**CLI subcommand wrappers** (`ClaudeWrapper.Commands.*`)

| Module | Description |
|---|---|
| `Commands.Auth` | Auth management (login modes, status, setup-token) |
| `Commands.Agents` | List active background agent sessions (`agents --json`) |
| `Commands.Mcp` | MCP server management (add/add-json/add-from-desktop/list/get/remove/serve) |
| `Commands.Plugin` | Plugin install/enable/disable/update/validate/tag/details/prune |
| `Commands.Marketplace` | Marketplace add/remove/list/update |
| `Commands.AutoMode` | auto-mode config/defaults/critique |
| `Commands.Ultrareview` | `ultrareview` (cloud multi-agent code review) |
| `Commands.Install` / `Commands.Update` | `claude install` / `claude update` |
| `Commands.Project` | `claude project purge` |
| `Commands.Doctor` / `Commands.Version` | CLI health check / version |

## License

MIT. See the `LICENSE` file in the source repo for the full text.
