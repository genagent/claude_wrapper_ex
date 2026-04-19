# ClaudeWrapper

[![CI](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/claude_wrapper_ex/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/claude_wrapper.svg)](https://hex.pm/packages/claude_wrapper)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/claude_wrapper)

Elixir wrapper for the [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code).

Provides a typed interface for executing queries, streaming responses,
managing multi-turn sessions, and configuring MCP servers -- all from Elixir.

## Installation

```elixir
def deps do
  [
    {:claude_wrapper, "~> 0.1.0"}
  ]
end
```

Requires the `claude` CLI to be installed and on your PATH (or set `CLAUDE_CLI`
to point at it).

## Quick start

```elixir
# One-shot query
{:ok, result} = ClaudeWrapper.query("Explain this error: ...")
IO.puts(result.result)

# With options
{:ok, result} = ClaudeWrapper.query("Fix the bug in lib/foo.ex",
  model: "sonnet",
  working_dir: "/path/to/project",
  max_turns: 5,
  permission_mode: :bypass_permissions
)

# Streaming
ClaudeWrapper.stream("Implement the feature described in issue #42",
  working_dir: "/path/to/project"
)
|> Stream.each(fn event -> IO.inspect(event.type) end)
|> Stream.run()
```

## Multi-turn sessions

```elixir
config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")
session = ClaudeWrapper.Session.new(config, model: "sonnet")

{:ok, session, result} = ClaudeWrapper.Session.send(session, "What files are here?")
{:ok, session, result} = ClaudeWrapper.Session.send(session, "Add tests for lib/foo.ex")

ClaudeWrapper.Session.total_cost(session)
#=> 0.12
```

## IEx REPL

Use Claude conversationally from IEx:

```elixir
iex> import ClaudeWrapper.IEx

iex> chat("explain this codebase", working_dir: ".", model: "sonnet")
# => prints response
# ($0.07, 1 turn)

iex> say("now add tests for the retry module")
# => continues the conversation
# ($0.04 this turn, $0.11 total, 2 turns)

iex> cost()
# $0.11 across 2 turns

iex> history()
# prints full conversation

iex> session_id()
# "abc-123" -- save this to resume later

iex> reset()
# start fresh
```

## Workshop: multi-agent coordination

Workshop lets you run multiple Claude agents side by side from IEx.
Give each agent a name and a role, then coordinate them with a few
simple commands. You don't need to know Elixir to use it -- the
syntax is just function calls with atoms and strings.

### Setup

```
$ iex -S mix
```

The Workshop banner prints automatically with a command reference.

### Configure and create agents

```elixir
# Set shared config (do this first)
configure(
  working_dir: "~/projects/myapp",
  model: "sonnet",
  context: """
  Elixir project using Phoenix 1.7.
  Run mix test before considering any task complete.
  """
)

# Create agents with different roles
agent(:impl, "You write clean, well-tested code.", max_turns: 15)
agent(:reviewer, "You review code. Do not modify files.",
  model: "opus", allowed_tools: ["Read", "Bash"])
agent(:tests, "You focus exclusively on test coverage.",
  permission_mode: :bypass_permissions)
```

### Talk to agents

```elixir
# Synchronous -- blocks until done, prints the result
ask(:impl, "Implement caching for the user lookup")
ask(:impl, "What files did you change?")    # continues the conversation

# Asynchronous -- returns immediately
cast(:impl, "Implement the retry logic from issue #34")
cast(:tests, "Add property-based tests for lib/myapp/encoder.ex")

# Check on progress
status()
#  agent     | status  | task                                 | cost  | turns
# -----------+---------+--------------------------------------+-------+------
#  :impl     | working | Implement the retry logic from is... | $0.08 | 3
#  :reviewer | idle    |                                      | $0.00 | 0
#  :tests    | working | Add property-based tests for lib/... | $0.04 | 2

# Wait for results
await(:impl)       # wait for one
await_all()         # wait for everyone
```

### Coordinate agents

```elixir
# Pipe: send one agent's output to another
ask(:impl, "Implement the caching layer")
pipe(:impl, :reviewer, "Review for cache invalidation edge cases")

# Chain with |> (ask and pipe return the agent name)
ask(:impl, "Implement retry logic")
|> pipe(:reviewer, "Review for edge cases")
|> pipe(:tests, "Write tests for this")

# Fan: same question to multiple agents
fan("What issues do you see in lib/myapp/retry.ex?", [:impl, :reviewer])
await_all()
result(:impl)       # impl's take
result(:reviewer)   # reviewer's take
```

### Inspect and debug

```elixir
info(:impl)                    # detailed map (model, session_id, cost, ...)
result(:impl)                  # last response text
result(:impl, :full)           # full %Result{} struct
history(:impl)                 # print conversation
history(:impl, last: 3)        # last 3 turns only
inspect_agent(:impl, "prompt") # show the exact CLI command
cost()                         # itemized by agent
total_cost()                   # one number
```

### Lifecycle

```elixir
reset(:impl)     # clear conversation, keep role and config
dismiss(:impl)   # remove agent entirely
reset_all()      # stop everything, start over
```

## Query builder

For full control, use the `Query` struct directly:

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

## SessionServer (GenServer)

For OTP applications that need a supervised, process-based session:

```elixir
{:ok, pid} = ClaudeWrapper.SessionServer.start_link(
  config: config,
  query_opts: [model: "sonnet", max_turns: 5]
)

{:ok, result} = ClaudeWrapper.SessionServer.send_message(pid, "Fix the tests")
ClaudeWrapper.SessionServer.total_cost(pid)
```

Works with supervision trees:

```elixir
children = [
  {ClaudeWrapper.SessionServer,
   name: :my_agent, config: config, query_opts: [model: "sonnet"]}
]
```

## Plugin management

```elixir
alias ClaudeWrapper.Commands.Plugin

{:ok, plugins} = Plugin.list(config)
{:ok, _} = Plugin.install(config, "my-plugin", scope: :project)
{:ok, _} = Plugin.enable(config, "my-plugin")
{:ok, _} = Plugin.disable(config, "my-plugin")
{:ok, _} = Plugin.uninstall(config, "my-plugin")
```

## Marketplace management

```elixir
alias ClaudeWrapper.Commands.Marketplace

{:ok, marketplaces} = Marketplace.list(config)
{:ok, _} = Marketplace.add(config, "https://github.com/org/marketplace")
{:ok, _} = Marketplace.remove(config, "my-marketplace")
{:ok, _} = Marketplace.update(config)
```

## Telemetry

ClaudeWrapper emits `:telemetry` events around its core exec paths
so downstream applications can observe query/session/stream lifecycle
with a single handler.

Events (all use the `:telemetry.span/3` shape with `:start`, `:stop`,
and `:exception` suffixes):

| Event | Emitted by |
|---|---|
| `[:claude_wrapper, :exec, _]` | `ClaudeWrapper.Query.execute/2` (one-shot query) |
| `[:claude_wrapper, :stream, _]` | `ClaudeWrapper.Query.stream/2` (NDJSON streaming) |
| `[:claude_wrapper, :session, :turn, _]` | `ClaudeWrapper.Session.send/3` (single turn) |

Start metadata:

- `:command` -- atom (`:query`, `:stream`, `:session_turn`)
- `:session_id` -- when known (resumed or provided)
- `:model` -- from the query's `model` field
- `:resume?` -- boolean, whether this call threads a previous session

Stop metadata adds:

- `:cost_usd` -- parsed from the final NDJSON result when available
- `:exit_code` -- `0` on success, non-zero when the CLI exited with an error

Subscribe with:

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

## Raw CLI escape hatch

For subcommands not yet wrapped:

```elixir
ClaudeWrapper.raw(["config", "list"])
```

## Modules

| Module | Description |
|---|---|
| `ClaudeWrapper` | Convenience API |
| `ClaudeWrapper.Config` | Shared client config |
| `ClaudeWrapper.Query` | Query builder + execute/stream |
| `ClaudeWrapper.Result` | Parsed JSON result |
| `ClaudeWrapper.StreamEvent` | NDJSON streaming event |
| `ClaudeWrapper.Session` | Multi-turn session management |
| `ClaudeWrapper.SessionServer` | GenServer wrapper for sessions |
| `ClaudeWrapper.McpConfig` | `.mcp.json` builder |
| `ClaudeWrapper.Retry` | Exponential backoff retry |
| `ClaudeWrapper.Telemetry` | `:telemetry` spans for exec/stream/session |
| `ClaudeWrapper.IEx` | Interactive REPL helpers |
| `ClaudeWrapper.Workshop` | Multi-agent IEx coordination |
| `ClaudeWrapper.Commands.Auth` | Auth management |
| `ClaudeWrapper.Commands.Mcp` | MCP server CRUD |
| `ClaudeWrapper.Commands.Plugin` | Plugin install/enable/disable/update |
| `ClaudeWrapper.Commands.Marketplace` | Marketplace add/remove/list/update |
| `ClaudeWrapper.Commands.Doctor` | CLI health check |
| `ClaudeWrapper.Commands.Version` | CLI version |

## License

MIT -- see [LICENSE](LICENSE).
