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

  alias ClaudeWrapper.{Command, Config, Result, StreamEvent, Telemetry}

  @type permission_mode ::
          :default | :accept_edits | :bypass_permissions | :dont_ask | :plan | :auto

  @type output_format :: :text | :json | :stream_json
  @type input_format :: :text | :stream_json
  @type effort :: :low | :medium | :high | :max

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
          worktree: boolean(),
          brief: boolean(),
          debug_filter: String.t() | nil,
          debug_file: String.t() | nil,
          betas: String.t() | nil,
          plugin_dirs: [String.t()],
          setting_sources: String.t() | nil,
          tmux: boolean()
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
    :agent,
    :agents_json,
    :input_format,
    :settings,
    :debug_filter,
    :debug_file,
    :betas,
    :setting_sources,
    allowed_tools: [],
    disallowed_tools: [],
    mcp_config: [],
    add_dir: [],
    tools: [],
    files: [],
    plugin_dirs: [],
    continue_session: false,
    no_session_persistence: false,
    dangerously_skip_permissions: false,
    include_partial_messages: false,
    strict_mcp_config: false,
    fork_session: false,
    worktree: false,
    brief: false,
    tmux: false
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

  @doc "Add an allowed tool."
  @spec allowed_tool(t(), String.t()) :: t()
  def allowed_tool(%__MODULE__{} = q, tool), do: %{q | allowed_tools: q.allowed_tools ++ [tool]}

  @doc "Add a disallowed tool."
  @spec disallowed_tool(t(), String.t()) :: t()
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

  @doc "Create a git worktree for execution."
  @spec worktree(t()) :: t()
  def worktree(%__MODULE__{} = q), do: %{q | worktree: true}

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

  @doc "Set settings source list."
  @spec setting_sources(t(), String.t()) :: t()
  def setting_sources(%__MODULE__{} = q, sources), do: %{q | setting_sources: sources}

  @doc "Create tmux session."
  @spec tmux(t()) :: t()
  def tmux(%__MODULE__{} = q), do: %{q | tmux: true}

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
  defp apply_opt({:output_format, v}, q), do: output_format(q, v)
  defp apply_opt({:input_format, v}, q), do: input_format(q, v)
  defp apply_opt({:settings, v}, q), do: settings(q, v)
  defp apply_opt({:debug_filter, v}, q), do: debug_filter(q, v)
  defp apply_opt({:debug_file, v}, q), do: debug_file(q, v)
  defp apply_opt({:betas, v}, q), do: betas(q, v)
  defp apply_opt({:setting_sources, v}, q), do: setting_sources(q, v)

  # Boolean flags: only apply on true.
  defp apply_opt({:dangerously_skip_permissions, true}, q), do: dangerously_skip_permissions(q)
  defp apply_opt({:dangerously_skip_permissions, _}, q), do: q
  defp apply_opt({:continue_session, true}, q), do: continue_session(q)
  defp apply_opt({:continue_session, _}, q), do: q
  defp apply_opt({:no_session_persistence, true}, q), do: no_session_persistence(q)
  defp apply_opt({:no_session_persistence, _}, q), do: q
  defp apply_opt({:worktree, true}, q), do: worktree(q)
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
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, term()}
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

      {:error, {:exit, code, stdout}} ->
        # CLI may exit non-zero but still produce valid JSON (e.g. max_turns reached)
        case parse_json_output(stdout) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:error, {:exit, code, stdout}}
        end

      {:error, _} = error ->
        error
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
    |> add_list("--allowed-tools", q.allowed_tools)
    |> add_list("--disallowed-tools", q.disallowed_tools)
    |> add_list("--mcp-config", q.mcp_config)
    |> add_list("--add-dir", q.add_dir)
    |> add_opt("--effort", format_effort(q.effort))
    |> add_opt("--max-turns", q.max_turns && to_string(q.max_turns))
    |> add_opt("--json-schema", q.json_schema)
    |> add_bool("--continue", q.continue_session)
    |> add_opt("--resume", q.resume)
    |> add_opt("--session-id", q.session_id)
    |> add_opt("--fallback-model", q.fallback_model)
    |> add_bool("--no-session-persistence", q.no_session_persistence)
    |> add_bool("--dangerously-skip-permissions", q.dangerously_skip_permissions)
    |> add_opt("--agent", q.agent)
    |> add_opt("--agents-json", q.agents_json)
    |> add_list("--tool", q.tools)
    |> add_list("--file", q.files)
    |> add_bool("--include-partial-messages", q.include_partial_messages)
    |> add_opt("--input-format", format_input_format(q.input_format))
    |> add_bool("--strict-mcp-config", q.strict_mcp_config)
    |> add_opt("--settings", q.settings)
    |> add_bool("--fork-session", q.fork_session)
    |> add_bool("--worktree", q.worktree)
    |> add_bool("--brief", q.brief)
    |> add_opt("--debug-filter", q.debug_filter)
    |> add_opt("--debug-file", q.debug_file)
    |> add_opt("--betas", q.betas)
    |> add_list("--plugin-dir", q.plugin_dirs)
    |> add_opt("--setting-sources", q.setting_sources)
    |> add_bool("--tmux", q.tmux)
  end

  defp add_flag(args, flag, value), do: args ++ [flag, value]
  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, value]
  defp add_bool(args, _flag, false), do: args
  defp add_bool(args, flag, true), do: args ++ [flag]
  defp add_list(args, _flag, []), do: args
  defp add_list(args, flag, values), do: args ++ Enum.flat_map(values, &[flag, &1])

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
  defp format_effort(:max), do: "max"

  defp format_input_format(nil), do: nil
  defp format_input_format(:text), do: "text"
  defp format_input_format(:stream_json), do: "stream-json"

  defp parse_json_output(stdout) do
    json_line = extract_json(stdout)

    case Jason.decode(json_line) do
      {:ok, data} -> {:ok, Result.from_json(data)}
      {:error, reason} -> {:error, {:json_decode, reason, stdout}}
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
      {stdout, code} -> {:error, {:exit, code, stdout}}
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd, e}}
  end

  defp run_cmd(binary, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(binary, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {stdout, 0}} -> {:ok, stdout}
      {:ok, {stdout, code}} -> {:error, {:exit, code, stdout}}
      nil -> {:error, {:timeout, timeout}}
    end
  end

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
