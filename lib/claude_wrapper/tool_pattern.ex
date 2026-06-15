defmodule ClaudeWrapper.ToolPattern do
  @moduledoc """
  Tool permission patterns for `--allowed-tools` / `--disallowed-tools`.

  The Claude CLI accepts three pattern shapes in its tool lists:

    * Bare name: `Bash`, `Read`, `Write`.
    * Name with argument glob: `Bash(git log:*)`, `Write(src/*.ex)`.
    * MCP pattern: `mcp__server__tool` or `mcp__server__*`.

  This struct models all three. The typed constructors (`tool/1`,
  `tool_with_args/2`, `all/1`, `mcp/2`) always produce well-formed
  output. `parse/1` validates the shape of a raw string and returns a
  `t:pattern_error/0` on malformed input.

  For back-compat, the loose constructors (and the string clauses on
  `ClaudeWrapper.Query.allowed_tool/2` / `disallowed_tool/2`) accept any
  string and store it verbatim, so callers passing raw CLI strings keep
  working without changes. Use `parse/1` directly when you want to catch
  typos before the CLI invocation.

  This is the Elixir port of the Rust crate's `ToolPattern` /
  `PatternError` (`../claude-wrapper/src/tool_pattern.rs`). Validation
  is shape-level only: tool names are not checked against any allowlist
  because the CLI's tool inventory evolves independently.

  ## Example

      iex> ClaudeWrapper.ToolPattern.tool_with_args("Bash", "git log:*") |> to_string()
      "Bash(git log:*)"

      iex> ClaudeWrapper.ToolPattern.all("Write") |> to_string()
      "Write(*)"

      iex> ClaudeWrapper.ToolPattern.mcp("my-server", "*") |> to_string()
      "mcp__my-server__*"
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @typedoc """
  Errors from `parse/1`.

    * `:empty` -- input was empty or all whitespace.
    * `:missing_name` -- the tool-name part was empty (e.g. `(args)`
      with nothing before the `(`).
    * `{:unbalanced_parens, original}` -- parentheses were unbalanced or
      appeared out of order. Carries the trimmed input.
    * `{:illegal_char, original}` -- contained a comma (splits the argv)
      or a control char (can break the shell). Carries the trimmed
      input.
  """
  @type pattern_error ::
          :empty
          | :missing_name
          | {:unbalanced_parens, String.t()}
          | {:illegal_char, String.t()}

  @doc """
  A bare tool name, e.g. `tool("Bash")` -> `Bash`.

  No validation beyond trimming whitespace; the CLI is the source of
  truth for which tool names exist. Use `parse/1` when you want shape
  validation.

      iex> ClaudeWrapper.ToolPattern.tool("  Bash  ") |> to_string()
      "Bash"
  """
  @spec tool(String.t()) :: t()
  def tool(name) when is_binary(name) do
    %__MODULE__{value: String.trim(name)}
  end

  @doc """
  A tool with an argument glob, rendered `Name(args)`.

      iex> ClaudeWrapper.ToolPattern.tool_with_args("Bash", "git log:*") |> to_string()
      "Bash(git log:*)"
  """
  @spec tool_with_args(String.t(), String.t()) :: t()
  def tool_with_args(name, args) when is_binary(name) and is_binary(args) do
    %__MODULE__{value: "#{String.trim(name)}(#{args})"}
  end

  @doc """
  Shorthand for `tool_with_args/2` with `*` as the argument pattern --
  "any args to this tool."

      iex> ClaudeWrapper.ToolPattern.all("Write") |> to_string()
      "Write(*)"
  """
  @spec all(String.t()) :: t()
  def all(name) when is_binary(name) do
    tool_with_args(name, "*")
  end

  @doc """
  An MCP pattern: `mcp__{server}__{tool}`. Pass `"*"` as the tool to
  match any tool from the server.

      iex> ClaudeWrapper.ToolPattern.mcp("my-server", "do_thing") |> to_string()
      "mcp__my-server__do_thing"

      iex> ClaudeWrapper.ToolPattern.mcp("my-server", "*") |> to_string()
      "mcp__my-server__*"
  """
  @spec mcp(String.t(), String.t()) :: t()
  def mcp(server, tool) when is_binary(server) and is_binary(tool) do
    %__MODULE__{value: "mcp__#{server}__#{tool}"}
  end

  @doc """
  Parse and validate a raw CLI-format pattern string.

  Validation is shape-level only (non-empty, balanced parens, no comma
  or control chars). Tool names are not checked against any allowlist
  because the CLI's tool inventory evolves independently. Surrounding
  whitespace is trimmed before validation, so leading/trailing control
  characters do not trip `{:illegal_char, _}`.

  Returns `{:ok, t}` or `{:error, t:pattern_error/0}`.

      iex> ClaudeWrapper.ToolPattern.parse("Bash(git log:*)")
      {:ok, %ClaudeWrapper.ToolPattern{value: "Bash(git log:*)"}}

      iex> ClaudeWrapper.ToolPattern.parse("")
      {:error, :empty}

      iex> ClaudeWrapper.ToolPattern.parse("(args)")
      {:error, :missing_name}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, pattern_error()}
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    with :ok <- check_non_empty(trimmed),
         :ok <- check_legal_chars(trimmed),
         :ok <- check_parens(trimmed) do
      {:ok, %__MODULE__{value: trimmed}}
    end
  end

  defp check_non_empty(""), do: {:error, :empty}
  defp check_non_empty(_trimmed), do: :ok

  defp check_legal_chars(trimmed) do
    if String.contains?(trimmed, ",") or has_control_char?(trimmed) do
      {:error, {:illegal_char, trimmed}}
    else
      :ok
    end
  end

  # Control chars are U+0000..U+001F and U+007F..U+009F, mirroring
  # Rust's `char::is_control`.
  defp has_control_char?(trimmed) do
    String.to_charlist(trimmed)
    |> Enum.any?(fn cp -> cp <= 0x1F or (cp >= 0x7F and cp <= 0x9F) end)
  end

  defp check_parens(trimmed) do
    opens = count_char(trimmed, "(")
    closes = count_char(trimmed, ")")

    cond do
      opens == 0 and closes == 0 -> :ok
      opens == 0 and closes > 0 -> {:error, {:unbalanced_parens, trimmed}}
      true -> check_balanced_parens(trimmed, opens, closes)
    end
  end

  defp check_balanced_parens(trimmed, opens, closes) do
    cond do
      not String.ends_with?(trimmed, ")") -> {:error, {:unbalanced_parens, trimmed}}
      opens != 1 or closes != 1 -> {:error, {:unbalanced_parens, trimmed}}
      String.starts_with?(trimmed, "(") -> {:error, :missing_name}
      true -> :ok
    end
  end

  defp count_char(string, char) do
    string |> String.graphemes() |> Enum.count(&(&1 == char))
  end

  @doc """
  Render the pattern as the string it will become in the CLI arg.

  The `String.Chars` protocol is also implemented, so the kernel
  `to_string/1` and string interpolation work too.

      iex> ClaudeWrapper.ToolPattern.to_string(ClaudeWrapper.ToolPattern.tool("Read"))
      "Read"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{value: value}), do: value

  defimpl String.Chars do
    def to_string(pattern), do: ClaudeWrapper.ToolPattern.to_string(pattern)
  end
end
