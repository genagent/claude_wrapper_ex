defmodule ClaudeWrapper.Query do
  @moduledoc """
  Query command -- the primary interface for executing prompts.

  Wraps `claude -p <prompt>` with the full set of CLI flags.

  ## Usage

      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")

      # Build a query
      query = ClaudeWrapper.Query.new("Fix the failing test")
        |> ClaudeWrapper.Query.model("sonnet")
        |> ClaudeWrapper.Query.max_turns(5)
        |> ClaudeWrapper.Query.permission_mode(:bypass_permissions)

      # Execute (one-shot, returns full result)
      {:ok, result} = ClaudeWrapper.Query.execute(query, config)

      # Or stream events
      ClaudeWrapper.Query.stream(query, config)
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()
  """

  alias ClaudeWrapper.{Auth, Command, Config, Error, Result, StreamEvent, Telemetry}

  @type permission_mode ::
          :default | :accept_edits | :bypass_permissions | :dont_ask | :plan | :auto

  @type output_format :: :text | :json | :stream_json
  @type input_format :: :text | :stream_json
  @type effort :: :low | :medium | :high | :xhigh | :max

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          append_system_prompt: String.t() | nil,
          output_format: output_format() | nil,
          max_budget_usd: float() | nil,
          permission_mode: permission_mode() | nil,
          allowed_tools: [String.t()],
          disallowed_tools: [String.t()],
          mcp_config: [String.t()],
          add_dir: [String.t()],
          effort: effort() | nil,
          max_turns: pos_integer() | nil,
          json_schema: String.t() | nil,
          continue_session: boolean(),
          resume: String.t() | nil,
          session_id: String.t() | nil,
          fallback_model: String.t() | nil,
          from_pr: String.t() | nil,
          no_session_persistence: boolean(),
          dangerously_skip_permissions: boolean(),
          agent: String.t() | nil,
          agents_json: String.t() | nil,
          tools: [String.t()],
          files: [String.t()],
          include_partial_messages: boolean(),
          input_format: input_format() | nil,
          strict_mcp_config: boolean(),
          settings: String.t() | nil,
          fork_session: boolean(),
          worktree: boolean() | String.t(),
          brief: boolean(),
          debug_filter: String.t() | nil,
          debug_file: String.t() | nil,
          betas: String.t() | nil,
          plugin_dirs: [String.t()],
          plugin_urls: [String.t()],
          name: String.t() | nil,
          safe_mode: boolean(),
          setting_sources: String.t() | nil,
          tmux: boolean(),
          prompt_suggestions: boolean(),
          replay_user_messages: boolean(),
          bare: boolean(),
          disable_slash_commands: boolean(),
          include_hook_events: boolean(),
          exclude_dynamic_system_prompt_sections: boolean()
        }

  defstruct [
    :prompt,
    :model,
    :system_prompt,
    :append_system_prompt,
    :output_format,
    :max_budget_usd,
    :permission_mode,
    :effort,
    :max_turns,
    :json_schema,
    :resume,
    :session_id,
    :fallback_model,
    :from_pr,
    :agent,
    :agents_json,
    :input_format,
    :settings,
    :debug_filter,
    :debug_file,
    :betas,
    :name,
    :setting_sources,
    allowed_tools: [],
    disallowed_tools: [],
    mcp_config: [],
    add_dir: [],
    tools: [],
    files: [],
    plugin_dirs: [],
    plugin_urls: [],
    safe_mode: false,
    continue_session: false,
    no_session_persistence: false,
    dangerously_skip_permissions: false,
    include_partial_messages: false,
    strict_mcp_config: false,
    fork_session: false,
    worktree: false,
    brief: false,
    tmux: false,
    prompt_suggestions: false,
    replay_user_messages: false,
    bare: false,
    disable_slash_commands: false,
    include_hook_events: false,
    exclude_dynamic_system_prompt_sections: false
  ]

  @doc """
  Create a new query with the given prompt.
  """
  @spec new(String.t()) :: t()
  def new(prompt) when is_binary(prompt) do
    %__MODULE__{prompt: prompt}
  end

  # Builder functions -- each returns the updated struct for piping.

  @doc ~s[Set the model (e.g. "sonnet", "opus", "haiku").]
  @spec model(t(), String.t()) :: t()
  def model(%__MODULE__{} = q, model), do: %{q | model: model}

  @doc "Set the system prompt (overrides default)."
  @spec system_prompt(t(), String.t()) :: t()
  def system_prompt(%__MODULE__{} = q, prompt), do: %{q | system_prompt: prompt}

  @doc "Append to the system prompt."
  @spec append_system_prompt(t(), String.t()) :: t()
  def append_system_prompt(%__MODULE__{} = q, prompt), do: %{q | append_system_prompt: prompt}

  @doc "Set output format."
  @spec output_format(t(), output_format()) :: t()
  def output_format(%__MODULE__{} = q, fmt), do: %{q | output_format: fmt}

  @doc "Set maximum budget in USD."
  @spec max_budget_usd(t(), float()) :: t()
  def max_budget_usd(%__MODULE__{} = q, budget), do: %{q | max_budget_usd: budget}

  @doc "Set permission mode."
  @spec permission_mode(t(), permission_mode()) :: t()
  def permission_mode(%__MODULE__{} = q, mode), do: %{q | permission_mode: mode}

  @doc """
  Add an allowed tool.

  Accepts either a plain CLI-format string (`"Bash(git log:*)"`) or a
  `t:ClaudeWrapper.ToolPattern.t/0`, which is rendered to its string
  form. The stored field stays a list of strings.
  """
  @spec allowed_tool(t(), String.t() | ClaudeWrapper.ToolPattern.t()) :: t()
  def allowed_tool(%__MODULE__{} = q, %ClaudeWrapper.ToolPattern{} = pattern),
    do: allowed_tool(q, ClaudeWrapper.ToolPattern.to_string(pattern))

  def allowed_tool(%__MODULE__{} = q, tool), do: %{q | allowed_tools: q.allowed_tools ++ [tool]}

  @doc """
  Add a disallowed tool.

  Accepts either a plain CLI-format string or a
  `t:ClaudeWrapper.ToolPattern.t/0`, mirroring `allowed_tool/2`.
  """
  @spec disallowed_tool(t(), String.t() | ClaudeWrapper.ToolPattern.t()) :: t()
  def disallowed_tool(%__MODULE__{} = q, %ClaudeWrapper.ToolPattern{} = pattern),
    do: disallowed_tool(q, ClaudeWrapper.ToolPattern.to_string(pattern))

  def disallowed_tool(%__MODULE__{} = q, tool),
    do: %{q | disallowed_tools: q.disallowed_tools ++ [tool]}

  @doc "Add an MCP config file path."
  @spec mcp_config(t(), String.t()) :: t()
  def mcp_config(%__MODULE__{} = q, path), do: %{q | mcp_config: q.mcp_config ++ [path]}

  @doc "Add a directory for tool access."
  @spec add_dir(t(), String.t()) :: t()
  def add_dir(%__MODULE__{} = q, dir), do: %{q | add_dir: q.add_dir ++ [dir]}

  @doc "Set effort level."
  @spec effort(t(), effort()) :: t()
  def effort(%__MODULE__{} = q, level), do: %{q | effort: level}

  @doc "Set maximum turns."
  @spec max_turns(t(), pos_integer()) :: t()
  def max_turns(%__MODULE__{} = q, n), do: %{q | max_turns: n}

  @doc "Set JSON schema for structured output."
  @spec json_schema(t(), String.t()) :: t()
  def json_schema(%__MODULE__{} = q, schema), do: %{q | json_schema: schema}

  @doc "Continue the most recent session."
  @spec continue_session(t()) :: t()
  def continue_session(%__MODULE__{} = q), do: %{q | continue_session: true}

  @doc "Resume a specific session by ID."
  @spec resume(t(), String.t()) :: t()
  def resume(%__MODULE__{} = q, id), do: %{q | resume: id}

  @doc "Use a specific session ID."
  @spec session_id(t(), String.t()) :: t()
  def session_id(%__MODULE__{} = q, id), do: %{q | session_id: id}

  @doc "Set a fallback model."
  @spec fallback_model(t(), String.t()) :: t()
  def fallback_model(%__MODULE__{} = q, model), do: %{q | fallback_model: model}

  @doc """
  Resume a session linked to a PR (`--from-pr <number|url>`).

  Analogous to `resume/2` but keyed on a pull request rather than a
  session id. The value is a PR number or URL.
  """
  @spec from_pr(t(), String.t()) :: t()
  def from_pr(%__MODULE__{} = q, pr), do: %{q | from_pr: pr}

  @doc "Disable session persistence."
  @spec no_session_persistence(t()) :: t()
  def no_session_persistence(%__MODULE__{} = q), do: %{q | no_session_persistence: true}

  @doc "Bypass all permission checks. Use in isolated worktrees."
  @spec dangerously_skip_permissions(t()) :: t()
  def dangerously_skip_permissions(%__MODULE__{} = q),
    do: %{q | dangerously_skip_permissions: true}

  @doc "Set agent name."
  @spec agent(t(), String.t()) :: t()
  def agent(%__MODULE__{} = q, name), do: %{q | agent: name}

  @doc "Provide custom agents as JSON."
  @spec agents_json(t(), String.t()) :: t()
  def agents_json(%__MODULE__{} = q, json), do: %{q | agents_json: json}

  @doc "Add a tool."
  @spec tool(t(), String.t()) :: t()
  def tool(%__MODULE__{} = q, tool), do: %{q | tools: q.tools ++ [tool]}

  @doc "Add a file resource."
  @spec file(t(), String.t()) :: t()
  def file(%__MODULE__{} = q, path), do: %{q | files: q.files ++ [path]}

  @doc "Include partial messages in streaming output."
  @spec include_partial_messages(t()) :: t()
  def include_partial_messages(%__MODULE__{} = q), do: %{q | include_partial_messages: true}

  @doc "Set input format."
  @spec input_format(t(), input_format()) :: t()
  def input_format(%__MODULE__{} = q, fmt), do: %{q | input_format: fmt}

  @doc "Only use servers from --mcp-config."
  @spec strict_mcp_config(t()) :: t()
  def strict_mcp_config(%__MODULE__{} = q), do: %{q | strict_mcp_config: true}

  @doc "Set settings JSON."
  @spec settings(t(), String.t()) :: t()
  def settings(%__MODULE__{} = q, json), do: %{q | settings: json}

  @doc "Fork to a new session."
  @spec fork_session(t()) :: t()
  def fork_session(%__MODULE__{} = q), do: %{q | fork_session: true}

  @doc "Create a git worktree for execution (`--worktree`). See `worktree/2` for a named worktree."
  @spec worktree(t()) :: t()
  def worktree(%__MODULE__{} = q), do: %{q | worktree: true}

  @doc "Create a named git worktree for execution (`--worktree <name>`)."
  @spec worktree(t(), String.t()) :: t()
  def worktree(%__MODULE__{} = q, name) when is_binary(name), do: %{q | worktree: name}

  @doc "Enable brief mode."
  @spec brief(t()) :: t()
  def brief(%__MODULE__{} = q), do: %{q | brief: true}

  @doc "Set debug filter."
  @spec debug_filter(t(), String.t()) :: t()
  def debug_filter(%__MODULE__{} = q, filter), do: %{q | debug_filter: filter}

  @doc "Set debug log file."
  @spec debug_file(t(), String.t()) :: t()
  def debug_file(%__MODULE__{} = q, path), do: %{q | debug_file: path}

  @doc "Set beta feature headers."
  @spec betas(t(), String.t()) :: t()
  def betas(%__MODULE__{} = q, betas), do: %{q | betas: betas}

  @doc "Add a plugin directory."
  @spec plugin_dir(t(), String.t()) :: t()
  def plugin_dir(%__MODULE__{} = q, dir), do: %{q | plugin_dirs: q.plugin_dirs ++ [dir]}

  @doc "Fetch a plugin `.zip` from a URL (`--plugin-url`). Repeatable."
  @spec plugin_url(t(), String.t()) :: t()
  def plugin_url(%__MODULE__{} = q, url), do: %{q | plugin_urls: q.plugin_urls ++ [url]}

  @doc "Set a display name for the session (`--name`)."
  @spec name(t(), String.t()) :: t()
  def name(%__MODULE__{} = q, name), do: %{q | name: name}

  @doc "Start with all customizations disabled (`--safe-mode`)."
  @spec safe_mode(t()) :: t()
  def safe_mode(%__MODULE__{} = q), do: %{q | safe_mode: true}

  @doc "Set settings source list."
  @spec setting_sources(t(), String.t()) :: t()
  def setting_sources(%__MODULE__{} = q, sources), do: %{q | setting_sources: sources}

  @doc "Create tmux session."
  @spec tmux(t()) :: t()
  def tmux(%__MODULE__{} = q), do: %{q | tmux: true}

  @doc "Enable prompt suggestions (`--prompt-suggestions`)."
  @spec prompt_suggestions(t()) :: t()
  def prompt_suggestions(%__MODULE__{} = q), do: %{q | prompt_suggestions: true}

  @doc "Re-emit user messages from stdin (`--replay-user-messages`). Mainly for stream/duplex use."
  @spec replay_user_messages(t()) :: t()
  def replay_user_messages(%__MODULE__{} = q), do: %{q | replay_user_messages: true}

  @doc "Minimal mode: skip hooks, LSP, plugins, and settings (`--bare`)."
  @spec bare(t()) :: t()
  def bare(%__MODULE__{} = q), do: %{q | bare: true}

  @doc "Disable all slash commands / skills (`--disable-slash-commands`)."
  @spec disable_slash_commands(t()) :: t()
  def disable_slash_commands(%__MODULE__{} = q), do: %{q | disable_slash_commands: true}

  @doc "Include hook lifecycle events in the output stream (`--include-hook-events`)."
  @spec include_hook_events(t()) :: t()
  def include_hook_events(%__MODULE__{} = q), do: %{q | include_hook_events: true}

  @doc "Exclude dynamic system-prompt sections (`--exclude-dynamic-system-prompt-sections`)."
  @spec exclude_dynamic_system_prompt_sections(t()) :: t()
  def exclude_dynamic_system_prompt_sections(%__MODULE__{} = q),
    do: %{q | exclude_dynamic_system_prompt_sections: true}

  # --- Bulk option application ---

  @doc """
  Apply a keyword list of options to a query, calling the equivalent
  `Query` setter for each known key. Unknown keys are silently ignored.

  This is the shared mapping used by `ClaudeWrapper.query/2`,
  `ClaudeWrapper.stream/2`, and `ClaudeWrapper.Session.send/3`. It
  exists so the opt-to-setter mapping lives in one place rather than
  being duplicated across each surface.

  Boolean opts (e.g. `:worktree`, `:dangerously_skip_permissions`)
  are applied when the value is `true` and ignored when `false`. List
  opts (e.g. `:allowed_tools`, `:add_dir`) reduce over their list,
  applying the per-item setter for each entry.

  ## Examples

      iex> q = ClaudeWrapper.Query.new("hi")
      iex> q = ClaudeWrapper.Query.apply_opts(q, model: "sonnet", max_turns: 3, worktree: true)
      iex> q.model
      "sonnet"
      iex> q.max_turns
      3
      iex> q.worktree
      true
  """
  @spec apply_opts(t(), keyword()) :: t()
  def apply_opts(%__MODULE__{} = query, opts) when is_list(opts) do
    Enum.reduce(opts, query, &apply_opt/2)
  end

  defp apply_opt({:model, v}, q), do: model(q, v)
  defp apply_opt({:system_prompt, v}, q), do: system_prompt(q, v)
  defp apply_opt({:append_system_prompt, v}, q), do: append_system_prompt(q, v)
  defp apply_opt({:max_turns, v}, q), do: max_turns(q, v)
  defp apply_opt({:max_budget_usd, v}, q), do: max_budget_usd(q, v)
  defp apply_opt({:permission_mode, v}, q), do: permission_mode(q, v)
  defp apply_opt({:effort, v}, q), do: effort(q, v)
  defp apply_opt({:json_schema, v}, q), do: json_schema(q, v)
  defp apply_opt({:agent, v}, q), do: agent(q, v)
  defp apply_opt({:agents_json, v}, q), do: agents_json(q, v)
  defp apply_opt({:session_id, v}, q), do: session_id(q, v)
  defp apply_opt({:resume, v}, q), do: resume(q, v)
  defp apply_opt({:fallback_model, v}, q), do: fallback_model(q, v)
  defp apply_opt({:from_pr, v}, q), do: from_pr(q, v)
  defp apply_opt({:output_format, v}, q), do: output_format(q, v)
  defp apply_opt({:input_format, v}, q), do: input_format(q, v)
  defp apply_opt({:settings, v}, q), do: settings(q, v)
  defp apply_opt({:debug_filter, v}, q), do: debug_filter(q, v)
  defp apply_opt({:debug_file, v}, q), do: debug_file(q, v)
  defp apply_opt({:betas, v}, q), do: betas(q, v)
  defp apply_opt({:name, v}, q), do: name(q, v)
  defp apply_opt({:setting_sources, v}, q), do: setting_sources(q, v)

  # Boolean flags: only apply on true.
  defp apply_opt({:dangerously_skip_permissions, true}, q), do: dangerously_skip_permissions(q)
  defp apply_opt({:dangerously_skip_permissions, _}, q), do: q
  defp apply_opt({:continue_session, true}, q), do: continue_session(q)
  defp apply_opt({:continue_session, _}, q), do: q
  defp apply_opt({:no_session_persistence, true}, q), do: no_session_persistence(q)
  defp apply_opt({:no_session_persistence, _}, q), do: q
  defp apply_opt({:worktree, true}, q), do: worktree(q)
  defp apply_opt({:worktree, name}, q) when is_binary(name), do: worktree(q, name)
  defp apply_opt({:worktree, _}, q), do: q
  defp apply_opt({:brief, true}, q), do: brief(q)
  defp apply_opt({:brief, _}, q), do: q
  defp apply_opt({:fork_session, true}, q), do: fork_session(q)
  defp apply_opt({:fork_session, _}, q), do: q
  defp apply_opt({:strict_mcp_config, true}, q), do: strict_mcp_config(q)
  defp apply_opt({:strict_mcp_config, _}, q), do: q
  defp apply_opt({:include_partial_messages, true}, q), do: include_partial_messages(q)
  defp apply_opt({:include_partial_messages, _}, q), do: q
  defp apply_opt({:tmux, true}, q), do: tmux(q)
  defp apply_opt({:tmux, _}, q), do: q
  defp apply_opt({:prompt_suggestions, true}, q), do: prompt_suggestions(q)
  defp apply_opt({:prompt_suggestions, _}, q), do: q
  defp apply_opt({:replay_user_messages, true}, q), do: replay_user_messages(q)
  defp apply_opt({:replay_user_messages, _}, q), do: q
  defp apply_opt({:bare, true}, q), do: bare(q)
  defp apply_opt({:bare, _}, q), do: q
  defp apply_opt({:disable_slash_commands, true}, q), do: disable_slash_commands(q)
  defp apply_opt({:disable_slash_commands, _}, q), do: q
  defp apply_opt({:include_hook_events, true}, q), do: include_hook_events(q)
  defp apply_opt({:include_hook_events, _}, q), do: q
  defp apply_opt({:safe_mode, true}, q), do: safe_mode(q)
  defp apply_opt({:safe_mode, _}, q), do: q

  defp apply_opt({:exclude_dynamic_system_prompt_sections, true}, q),
    do: exclude_dynamic_system_prompt_sections(q)

  defp apply_opt({:exclude_dynamic_system_prompt_sections, _}, q), do: q

  # List opts (or single value, where it makes sense).
  defp apply_opt({:allowed_tools, tools}, q) when is_list(tools),
    do: Enum.reduce(tools, q, &allowed_tool(&2, &1))

  defp apply_opt({:disallowed_tools, tools}, q) when is_list(tools),
    do: Enum.reduce(tools, q, &disallowed_tool(&2, &1))

  defp apply_opt({:tools, tools}, q) when is_list(tools),
    do: Enum.reduce(tools, q, &tool(&2, &1))

  defp apply_opt({:add_dir, dirs}, q) when is_list(dirs),
    do: Enum.reduce(dirs, q, &add_dir(&2, &1))

  defp apply_opt({:add_dir, dir}, q) when is_binary(dir), do: add_dir(q, dir)

  defp apply_opt({:files, files}, q) when is_list(files),
    do: Enum.reduce(files, q, &file(&2, &1))

  defp apply_opt({:plugin_dirs, dirs}, q) when is_list(dirs),
    do: Enum.reduce(dirs, q, &plugin_dir(&2, &1))

  defp apply_opt({:plugin_urls, urls}, q) when is_list(urls),
    do: Enum.reduce(urls, q, &plugin_url(&2, &1))

  defp apply_opt({:mcp_config, paths}, q) when is_list(paths),
    do: Enum.reduce(paths, q, &mcp_config(&2, &1))

  defp apply_opt({:mcp_config, path}, q) when is_binary(path), do: mcp_config(q, path)

  # Unknown option: ignore. Documented above.
  defp apply_opt(_other, q), do: q

  # --- Execution ---

  @doc """
  Execute the query synchronously, returning a parsed `%Result{}`.

  Automatically sets `--output-format json` for parsing.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def execute(%__MODULE__{} = query, %Config{} = config) do
    query = %{query | output_format: :json}

    Telemetry.span_exec(query, fn -> do_execute(query, config) end)
  end

  defp do_execute(%__MODULE__{} = query, %Config{} = config) do
    # Strip --verbose from base args: it causes the CLI to emit non-JSON
    # output (NDJSON stream lines, stdin warnings) that breaks JSON parsing.
    # Verbose is only meaningful for stream-json output.
    base = Config.base_args(config) -- ["--verbose"]
    args = base ++ build_args(query)
    opts = Config.cmd_opts(config)

    case run_cmd(config.binary, args, opts, config.timeout) do
      {:ok, stdout} ->
        parse_json_output(stdout)

      {:error, %Error{kind: :command_failed, exit_code: code, stdout: stdout}} ->
        handle_nonzero_exit(code, stdout)

      {:error, _} = error ->
        error
    end
  end

  # A non-zero CLI exit that still emits valid JSON is not always a hard
  # failure: the CLI reports its rail-stop caps (--max-turns and
  # --max-budget-usd) this way, and we surface each as its own typed
  # error carrying the run's cost/turn figures; any other valid-JSON
  # result keeps its `is_error` flag and returns `{:ok, %Result{}}`.
  # When the output is not decodable JSON the exit is a genuine command
  # failure -- classified as an auth error first when it looks
  # auth-shaped, otherwise plain.
  @doc false
  @spec handle_nonzero_exit(integer(), String.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def handle_nonzero_exit(code, stdout) do
    case parse_json_output(stdout) do
      {:ok, result} ->
        case rail_stop_kind(result) do
          nil ->
            {:ok, result}

          {kind, cap} ->
            reason = %{
              cap: cap,
              cost_usd: result.cost_usd,
              num_turns: result.num_turns,
              session_id: result.session_id
            }

            {:error, Error.new(kind, reason: reason, exit_code: code, stdout: stdout)}
        end

      {:error, _} ->
        classify_command_failure(code, stdout)
    end
  end

  # Classify a terminal `result` event by its rail-stop subtype,
  # returning `{error_kind, parsed_cap}` or `nil`. The cap is pulled
  # from the human message ("Reached maximum number of turns (N)" /
  # "Reached maximum budget ($X)"); it may be `nil` if absent.
  defp rail_stop_kind(%Result{extra: extra, result: message}) do
    case Map.get(extra, "subtype") do
      "error_max_turns" -> {:max_turns_exceeded, parse_cap(message, :int)}
      "error_max_budget_usd" -> {:max_budget_exceeded, parse_cap(message, :float)}
      _ -> nil
    end
  end

  defp parse_cap(message, type) when is_binary(message) do
    case Regex.run(~r/\(\$?([0-9]+(?:\.[0-9]+)?)\)/, message) do
      [_, captured] -> cast_cap(captured, type)
      nil -> nil
    end
  end

  defp cast_cap(captured, :int) do
    case Integer.parse(captured) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp cast_cap(captured, :float) do
    case Float.parse(captured) do
      {n, _} -> n
      :error -> nil
    end
  end

  # A non-zero exit with no parseable JSON: run the auth classifier over
  # the output and, when it recognizes an auth-shaped failure, surface a
  # typed `:auth` error carrying the classified kind in `:reason`.
  # Otherwise fall back to a plain `:command_failed`.
  defp classify_command_failure(code, stdout) do
    case Auth.classify_failure(code, stdout, "") do
      nil ->
        {:error, Error.command_failed(code, stdout)}

      kind ->
        {:error, Error.new(:auth, reason: kind, exit_code: code, stdout: stdout)}
    end
  end

  @doc """
  Execute the query and return a lazy stream of `%StreamEvent{}`.

  Uses a Port with `:line` mode to read NDJSON output line-by-line.
  The port is opened when the stream is consumed and closed when
  the stream terminates.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = query, %Config{} = config) do
    query = %{query | output_format: :stream_json}

    Telemetry.span_stream(query, fn -> do_stream(query, config) end)
  end

  defp do_stream(%__MODULE__{} = query, %Config{} = config) do
    # stream-json with --print requires --verbose
    base = Config.base_args(config)
    base = if "--verbose" in base, do: base, else: ["--verbose" | base]
    args = base ++ build_args(query)
    shell_args = Command.shell_cmd_args(config.binary, args)

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, shell_args}] ++
        port_env_opts(config) ++
        port_cd_opts(config)

    Stream.resource(
      fn ->
        Port.open({:spawn_executable, "/bin/sh"}, port_opts)
      end,
      fn port ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            case StreamEvent.parse(line) do
              {:ok, event} -> {[event], port}
              {:error, _} -> {[], port}
            end

          {^port, {:data, {:noeol, _partial}}} ->
            # Line exceeded buffer -- skip for now
            {[], port}

          {^port, {:exit_status, _code}} ->
            {:halt, port}
        after
          # Safety timeout for hung processes
          300_000 -> {:halt, port}
        end
      end,
      fn port ->
        send(port, {self(), :close})

        receive do
          {^port, :closed} -> :ok
        after
          5_000 -> :ok
        end
      end
    )
  end

  @doc """
  Build the shell command string (for debugging).
  """
  @spec to_command_string(t(), Config.t()) :: String.t()
  def to_command_string(%__MODULE__{} = query, %Config{} = config) do
    args = Config.base_args(config) ++ build_args(query)
    Enum.join([config.binary | args], " ")
  end

  # --- Arg building ---

  @doc false
  @spec build_args(t()) :: [String.t()]
  def build_args(%__MODULE__{} = q) do
    []
    |> add_flag("--print", q.prompt)
    |> add_opt("--model", q.model)
    |> add_opt("--system-prompt", q.system_prompt)
    |> add_opt("--append-system-prompt", q.append_system_prompt)
    |> add_opt("--output-format", format_output_format(q.output_format))
    |> add_opt("--max-budget-usd", q.max_budget_usd && to_string(q.max_budget_usd))
    |> add_opt("--permission-mode", format_permission_mode(q.permission_mode))
    |> add_variadic("--allowed-tools", q.allowed_tools)
    |> add_variadic("--disallowed-tools", q.disallowed_tools)
    |> add_list("--mcp-config", q.mcp_config)
    |> add_list("--add-dir", q.add_dir)
    |> add_opt("--effort", format_effort(q.effort))
    |> add_opt("--max-turns", q.max_turns && to_string(q.max_turns))
    |> add_opt("--json-schema", q.json_schema)
    |> add_bool("--continue", q.continue_session)
    |> add_opt("--resume", q.resume)
    |> add_opt("--session-id", q.session_id)
    |> add_opt("--fallback-model", q.fallback_model)
    |> add_opt("--from-pr", q.from_pr)
    |> add_bool("--no-session-persistence", q.no_session_persistence)
    |> add_bool("--dangerously-skip-permissions", q.dangerously_skip_permissions)
    |> add_opt("--agent", q.agent)
    |> add_opt("--agents", q.agents_json)
    |> add_variadic("--tools", q.tools)
    |> add_list("--file", q.files)
    |> add_bool("--include-partial-messages", q.include_partial_messages)
    |> add_opt("--input-format", format_input_format(q.input_format))
    |> add_bool("--strict-mcp-config", q.strict_mcp_config)
    |> add_opt("--settings", q.settings)
    |> add_bool("--fork-session", q.fork_session)
    |> add_worktree(q.worktree)
    |> add_bool("--brief", q.brief)
    |> add_opt("--debug", q.debug_filter)
    |> add_opt("--debug-file", q.debug_file)
    |> add_opt("--betas", q.betas)
    |> add_list("--plugin-dir", q.plugin_dirs)
    |> add_list("--plugin-url", q.plugin_urls)
    |> add_opt("--name", q.name)
    |> add_bool("--safe-mode", q.safe_mode)
    |> add_opt("--setting-sources", q.setting_sources)
    |> add_bool("--tmux", q.tmux)
    |> add_bool("--prompt-suggestions", q.prompt_suggestions)
    |> add_bool("--replay-user-messages", q.replay_user_messages)
    |> add_bool("--bare", q.bare)
    |> add_bool("--disable-slash-commands", q.disable_slash_commands)
    |> add_bool("--include-hook-events", q.include_hook_events)
    |> add_bool(
      "--exclude-dynamic-system-prompt-sections",
      q.exclude_dynamic_system_prompt_sections
    )
  end

  defp add_flag(args, flag, value), do: args ++ [flag, value]
  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

  # Variadic list flag: emit the flag once followed by all values, matching the
  # CLI's `<tools...>` contract (e.g. `--tools Read Bash`). Use this for flags
  # the CLI declares variadic rather than repeatable.
  defp add_variadic(args, _flag, []), do: args
  defp add_variadic(args, flag, values), do: args ++ [flag | values]

  # --worktree takes an optional name: bare flag when true, flag + name when a
  # string, omitted when false.
  defp add_worktree(args, false), do: args
  defp add_worktree(args, true), do: args ++ ["--worktree"]
  defp add_worktree(args, name) when is_binary(name), do: args ++ ["--worktree", name]

  defp format_output_format(nil), do: nil
  defp format_output_format(:text), do: "text"
  defp format_output_format(:json), do: "json"
  defp format_output_format(:stream_json), do: "stream-json"

  defp format_permission_mode(nil), do: nil
  defp format_permission_mode(:default), do: "default"
  defp format_permission_mode(:accept_edits), do: "acceptEdits"
  defp format_permission_mode(:bypass_permissions), do: "bypassPermissions"
  defp format_permission_mode(:dont_ask), do: "dontAsk"
  defp format_permission_mode(:plan), do: "plan"
  defp format_permission_mode(:auto), do: "auto"

  defp format_effort(nil), do: nil
  defp format_effort(:low), do: "low"
  defp format_effort(:medium), do: "medium"
  defp format_effort(:high), do: "high"
  defp format_effort(:xhigh), do: "xhigh"
  defp format_effort(:max), do: "max"

  defp format_input_format(nil), do: nil
  defp format_input_format(:text), do: "text"
  defp format_input_format(:stream_json), do: "stream-json"

  defp parse_json_output(stdout) do
    json_line = extract_json(stdout)

    case Jason.decode(json_line) do
      {:ok, data} -> {:ok, Result.from_json(data)}
      {:error, reason} -> {:error, Error.json(reason, stdout)}
    end
  end

  # Extract the last JSON line from output, skipping warnings/noise.
  defp extract_json(output) do
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find("", fn line ->
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "{")
    end)
  end

  defp run_cmd(binary, args, opts, nil) do
    case System.cmd(binary, args, opts) do
      {stdout, 0} -> {:ok, stdout}
      {stdout, code} -> {:error, Error.command_failed(code, stdout)}
    end
  rescue
    e in ErlangError -> {:error, Error.io(e)}
  end

  defp run_cmd(binary, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(binary, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {stdout, 0}} -> {:ok, stdout}
      {:ok, {stdout, code}} -> {:error, Error.command_failed(code, stdout)}
      nil -> {:error, Error.timeout(timeout)}
    end
  end

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
