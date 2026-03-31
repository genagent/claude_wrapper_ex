# ClaudeWrapper

[![CI](https://github.com/joshrotenberg/claude_wrapper_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/joshrotenberg/claude_wrapper_ex/actions/workflows/ci.yml)
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
| `ClaudeWrapper.McpConfig` | `.mcp.json` builder |
| `ClaudeWrapper.Retry` | Exponential backoff retry |
| `ClaudeWrapper.Commands.Auth` | Auth management |
| `ClaudeWrapper.Commands.Mcp` | MCP server CRUD |
| `ClaudeWrapper.Commands.Doctor` | CLI health check |
| `ClaudeWrapper.Commands.Version` | CLI version |

## License

MIT -- see [LICENSE](LICENSE).
