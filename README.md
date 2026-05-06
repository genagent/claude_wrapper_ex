# ClaudeWrapper

[![CI](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/claude_wrapper.svg)](https://hex.pm/packages/claude_wrapper)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/claude_wrapper)

Elixir wrapper for the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code).

`claude_wrapper` gives you two ways to drive `claude` from Elixir:

1. **`DuplexSession`** -- a `GenServer` that holds **one** `claude`
   subprocess open for the lifetime of a conversation, streams partial
   tokens as they arrive, lets you interrupt mid-turn, and routes
   tool-permission prompts back to your code. This is the right fit
   for chat UIs, agent runtimes, Phoenix-backed interfaces, and any
   long-running OTP process.
2. **One-shot `Query`** -- a single subprocess per turn, simple
   request/response. The right fit for `mix` tasks, escripts, batch
   jobs, and anything else that runs and exits.

The duplex mode is the same protocol the official
`@anthropic-ai/claude-agent-sdk` uses internally and that the
`@agentclientprotocol/claude-agent-acp` bridge relies on for IDE
integrations like Zed's agent panel. We surface it here so an OTP
host can use `claude` the same way an IDE backend would.

## Installation

```elixir
def deps do
  [
    {:claude_wrapper, "~> 0.6"}
  ]
end
```

Requires the `claude` CLI to be installed and on your `PATH` (or set
`CLAUDE_CLI` to point at it).

## DuplexSession (long-lived chat-style sessions)

Holds one `claude` subprocess open across many turns. Subscribers
see assistant messages, partial token deltas, and tool-call results
as they arrive.

```elixir
config = ClaudeWrapper.Config.new(working_dir: ".")
{:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config)

# Subscribe to live events.
:ok = ClaudeWrapper.DuplexSession.subscribe(pid)

# Send a turn; this resolves when the CLI emits its `result` event.
{:ok, result} = ClaudeWrapper.DuplexSession.send(pid, "Explain this codebase.")

# Inbox now contains:
#   {:claude, {:system_init, "abc-123"}}
#   {:claude, {:assistant, %{...}}}
#   {:claude, {:stream_event, %{...}}}    -- partial token deltas
#   {:claude, {:user, %{...}}}            -- tool results
#   {:claude, {:result, %ClaudeWrapper.Result{}}}

# Cancel an in-flight turn cleanly (no SIGKILL):
ClaudeWrapper.DuplexSession.interrupt(pid)

# Or close the whole session:
ClaudeWrapper.DuplexSession.close(pid)
```

### Permission callback

When the CLI wants to run a tool, it routes the prompt back through
your `:on_permission` callback. The callback can answer synchronously
or defer to a UI:

```elixir
on_permission = fn tool_name, _input ->
  case tool_name do
    "Bash" -> {:deny, "no shell tools in this session"}
    _      -> :allow
  end
end

{:ok, pid} =
  ClaudeWrapper.DuplexSession.start_link(
    config: config,
    on_permission: on_permission
  )
```

For human-in-the-loop UIs, return `:defer` from the callback and
answer later via `respond_to_permission/3`.

### Pairing with a `DynamicSupervisor`

Each session owns one Port. Pair them with a `DynamicSupervisor`
for per-conversation isolation, named registration, and standard
OTP restart semantics:

```elixir
{:ok, _} =
  DynamicSupervisor.start_child(
    MyApp.SessionsSupervisor,
    {ClaudeWrapper.DuplexSession, [config: config, name: {:via, Registry, ...}]}
  )
```

See `ClaudeWrapper.DuplexSession` for the full API and message
vocabulary.

## DuplexIEx (REPL helpers for the duplex session)

For interactive use, the `DuplexIEx` helpers store one session in
the IEx process dictionary and stream tokens to stdout as they
arrive:

```elixir
iex> import ClaudeWrapper.DuplexIEx

iex> start(working_dir: ".")
Claude session started.

iex> say("Explain the README briefly.")
...streams text live...
($0.0123, 1 turn)
:ok

iex> say("Now suggest a one-line tagline.")
...streams text live...
:ok

iex> close()
Session closed.
```

## One-shot queries

For short-lived consumers (mix tasks, escripts, batch jobs, anything
that does one thing and exits), the simpler request/response surface
spawns a fresh subprocess per turn:

```elixir
{:ok, result} = ClaudeWrapper.query("Explain this error: ...")

{:ok, result} =
  ClaudeWrapper.query("Fix the bug in lib/foo.ex",
    model: "sonnet",
    working_dir: "/path/to/project",
    max_turns: 5,
    permission_mode: :bypass_permissions
  )
```

Streaming events from a one-shot query:

```elixir
ClaudeWrapper.stream("Implement the feature in issue #42",
  working_dir: "/path/to/project"
)
|> Stream.each(fn event -> IO.inspect(event.type) end)
|> Stream.run()
```

For a per-call REPL, use `ClaudeWrapper.IEx`:

```elixir
iex> import ClaudeWrapper.IEx
iex> chat("explain this codebase", working_dir: ".")
iex> say("now add tests for the retry module")
iex> cost()
iex> reset()
```

### When to use `Session` vs `DuplexSession`

`ClaudeWrapper.Session` threads `--resume <session_id>` across one-
shot calls so you get multi-turn continuity without holding a
subprocess open. Use it when:

- You're outside an OTP host (no GenServer to own a long-lived port)
- You want a simple struct-passing API rather than a process API
- Each turn is far apart in wall time and the cold-start cost
  doesn't matter

```elixir
session = ClaudeWrapper.Session.new(config, model: "sonnet")
{:ok, session, result} = ClaudeWrapper.Session.send(session, "What files are here?")
{:ok, session, result} = ClaudeWrapper.Session.send(session, "Add tests for lib/foo.ex")
```

When in doubt: a long-running host (Phoenix server, agent runtime,
chat UI backend) wants `DuplexSession`; everything else wants
`Query` or `Session`.

## Query builder

For full control over flags, build a `Query` directly:

```elixir
alias ClaudeWrapper.{Config, Query}

config = Config.new(working_dir: "/path/to/project")

Query.new("Fix the tests")
|> Query.model("sonnet")
|> Query.max_turns(10)
|> Query.permission_mode(:bypass_permissions)
|> Query.allowed_tool("Read")
|> Query.allowed_tool("Write")
|> Query.execute(config)
```

`Query.apply_opts/2` accepts a keyword list version of any of these
setters; `ClaudeWrapper.query/2`, `ClaudeWrapper.stream/2`, and
`Session.send/3` all delegate to it, so you can pass any of those
opts uniformly.

## Multi-agent coordination

Multi-agent coordination has moved to a separate package,
[**agent_workshop**](https://hex.pm/packages/agent_workshop). It is
backend-agnostic and can drive Claude, Codex, or any agent that
implements its `Backend` behaviour. Use it alongside
`claude_wrapper`:

```elixir
def deps do
  [
    {:claude_wrapper, "~> 0.6"},
    {:agent_workshop, "~> 0.1"}
  ]
end
```

## Telemetry

ClaudeWrapper emits `:telemetry` events around its core exec paths
so downstream applications can observe query/session/stream
lifecycle with a single handler. Events use the `:telemetry.span/3`
shape with `:start`, `:stop`, and `:exception` suffixes:

| Event | Emitted by |
|---|---|
| `[:claude_wrapper, :exec, _]` | `Query.execute/2` (one-shot query) |
| `[:claude_wrapper, :stream, _]` | `Query.stream/2` (NDJSON streaming) |
| `[:claude_wrapper, :session, :turn, _]` | `Session.send/3` (single turn) |

Stop metadata adds `:cost_usd`, `:exit_code`, and the usual
`:duration`. Subscribe with:

```elixir
:telemetry.attach_many(
  "claude-wrapper-observer",
  [
    [:claude_wrapper, :exec, :stop],
    [:claude_wrapper, :stream, :stop],
    [:claude_wrapper, :session, :turn, :stop]
  ],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements.duration, metadata})
  end,
  nil
)
```

See `ClaudeWrapper.Telemetry` for the full event reference.

## SessionServer (supervised one-shot sessions)

For OTP applications that want a supervised process around the
per-call `Session` flow:

```elixir
{:ok, pid} =
  ClaudeWrapper.SessionServer.start_link(
    config: config,
    query_opts: [model: "sonnet", max_turns: 5]
  )

{:ok, result} = ClaudeWrapper.SessionServer.send_message(pid, "Fix the tests")
ClaudeWrapper.SessionServer.total_cost(pid)
```

`SessionServer` wraps `Session` (one subprocess per turn). For chat-
UI-style flows where partial-token streaming matters, prefer
`DuplexSession` instead.

## MCP config builder

Build `.mcp.json` files programmatically:

```elixir
ClaudeWrapper.McpConfig.new()
|> ClaudeWrapper.McpConfig.add_stdio("my-server", "npx", ["-y", "my-mcp-server"],
  env: %{"API_KEY" => "sk-..."}
)
|> ClaudeWrapper.McpConfig.add_sse("remote", "https://example.com/mcp")
|> ClaudeWrapper.McpConfig.write!(".mcp.json")
```

## Retry with backoff

```elixir
ClaudeWrapper.Retry.execute(query, config,
  max_retries: 3,
  base_delay_ms: 1_000,
  max_delay_ms: 30_000
)
```

## Plugin and marketplace management

```elixir
alias ClaudeWrapper.Commands.{Plugin, Marketplace}

{:ok, plugins} = Plugin.list(config)
{:ok, _} = Plugin.install(config, "my-plugin", scope: :project)

{:ok, marketplaces} = Marketplace.list(config)
{:ok, _} = Marketplace.add(config, "https://github.com/org/marketplace")
```

## Raw CLI escape hatch

For subcommands not yet wrapped:

```elixir
ClaudeWrapper.raw(["config", "list"])
```

## Modules

**Long-lived sessions (the headline feature)**

| Module | Description |
|---|---|
| `ClaudeWrapper.DuplexSession` | Long-lived stream-json session over a single `claude` subprocess |
| `ClaudeWrapper.DuplexIEx` | REPL helpers for `DuplexSession` |

**One-shot / per-call**

| Module | Description |
|---|---|
| `ClaudeWrapper` | Convenience API (`query/2`, `stream/2`) |
| `ClaudeWrapper.Query` | Query builder + execute/stream |
| `ClaudeWrapper.Session` | Multi-turn continuity over per-call subprocesses |
| `ClaudeWrapper.SessionServer` | Supervised wrapper for `Session` |
| `ClaudeWrapper.IEx` | REPL helpers for one-shot/per-call mode |

**Shared infrastructure**

| Module | Description |
|---|---|
| `ClaudeWrapper.Config` | Shared client config (binary, working_dir, env, timeout) |
| `ClaudeWrapper.Result` | Parsed result struct |
| `ClaudeWrapper.StreamEvent` | NDJSON streaming event |
| `ClaudeWrapper.McpConfig` | `.mcp.json` builder |
| `ClaudeWrapper.Retry` | Exponential backoff retry |
| `ClaudeWrapper.Telemetry` | `:telemetry` spans for exec/stream/session |

**CLI subcommand wrappers**

| Module | Description |
|---|---|
| `ClaudeWrapper.Commands.Auth` | Auth management |
| `ClaudeWrapper.Commands.Mcp` | MCP server CRUD |
| `ClaudeWrapper.Commands.Plugin` | Plugin install/enable/disable/update |
| `ClaudeWrapper.Commands.Marketplace` | Marketplace add/remove/list/update |
| `ClaudeWrapper.Commands.Doctor` | CLI health check |
| `ClaudeWrapper.Commands.Version` | CLI version |

## License

MIT. See the `LICENSE` file in the source repo for the full text.
