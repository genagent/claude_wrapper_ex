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

  alias ClaudeWrapper.{
    Auth,
    Config,
    Error,
    ExecutionEvidence,
    RateLimitObservation,
    Result,
    Runner,
    SessionObservation,
    StreamEvent,
    Telemetry
  }

  @type permission_mode ::
          :default | :accept_edits | :bypass_permissions | :dont_ask | :plan | :auto

  @type output_format :: :text | :json | :stream_json
  @type input_format :: :text | :stream_json
  @type effort :: :low | :medium | :high | :xhigh | :max
  @type hermetic :: :full | :project

  @type t :: %__MODULE__{
          prompt: String.t(),
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          append_system_prompt: String.t() | nil,
          system_prompt_file: String.t() | nil,
          append_system_prompt_file: String.t() | nil,
          permission_prompt_tool: String.t() | nil,
          max_thinking_tokens: pos_integer() | nil,
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
          betas: String.t() | [String.t()] | nil,
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
          exclude_dynamic_system_prompt_sections: boolean(),
          hermetic: hermetic() | nil
        }

  defstruct [
    :prompt,
    :model,
    :system_prompt,
    :append_system_prompt,
    :system_prompt_file,
    :append_system_prompt_file,
    :permission_prompt_tool,
    :max_thinking_tokens,
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
    :hermetic,
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

  @doc "Set the system prompt from a file (`--system-prompt-file`), avoiding ARG_MAX limits from inlining a large prompt as argv. Verified against claude CLI 2.1.170 (hidden from --help)."
  @spec system_prompt_file(t(), String.t()) :: t()
  def system_prompt_file(%__MODULE__{} = q, path), do: %{q | system_prompt_file: path}

  @doc "Append to the system prompt from a file (`--append-system-prompt-file`). Verified against claude CLI 2.1.170 (hidden from --help)."
  @spec append_system_prompt_file(t(), String.t()) :: t()
  def append_system_prompt_file(%__MODULE__{} = q, path),
    do: %{q | append_system_prompt_file: path}

  @doc "Delegate permission decisions to a custom MCP tool (`--permission-prompt-tool <tool>`) for programmatic headless gating. Verified against claude CLI 2.1.170 (hidden from --help)."
  @spec permission_prompt_tool(t(), String.t()) :: t()
  def permission_prompt_tool(%__MODULE__{} = q, tool), do: %{q | permission_prompt_tool: tool}

  @doc "Cap the thinking-token budget (`--max-thinking-tokens`), a finer control than `--effort`. Verified against claude CLI 2.1.170 (hidden from --help)."
  @spec max_thinking_tokens(t(), pos_integer()) :: t()
  def max_thinking_tokens(%__MODULE__{} = q, n), do: %{q | max_thinking_tokens: n}

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

  @doc """
  Set the JSON schema for structured output (claude's `--json-schema`).

  Accepts an encoded JSON string, or a map or list that is encoded with
  `Jason.encode!/1` (raising `Jason.EncodeError` if it cannot be encoded).
  """
  @spec json_schema(t(), String.t() | map() | list()) :: t()
  def json_schema(%__MODULE__{} = q, schema) when is_binary(schema),
    do: %{q | json_schema: schema}

  def json_schema(%__MODULE__{} = q, schema) when is_map(schema) or is_list(schema),
    do: %{q | json_schema: Jason.encode!(schema)}

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

  @doc "Enable the SendUserMessage tool for agent-to-user communication (`--brief`)."
  @spec brief(t()) :: t()
  def brief(%__MODULE__{} = q), do: %{q | brief: true}

  @doc "Set debug filter."
  @spec debug_filter(t(), String.t()) :: t()
  def debug_filter(%__MODULE__{} = q, filter), do: %{q | debug_filter: filter}

  @doc "Set debug log file."
  @spec debug_file(t(), String.t()) :: t()
  def debug_file(%__MODULE__{} = q, path), do: %{q | debug_file: path}

  @doc """
  Set beta feature header(s).

  Accepts a single string or a list -- the CLI's `--betas` is variadic, so a
  list emits one `--betas` flag followed by every value (a single string is
  still accepted, unchanged).
  """
  @spec betas(t(), String.t() | [String.t()]) :: t()
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

  @doc """
  Seal the ambient `~/.claude` config so a programmatic run's surface is
  exactly what was provided explicitly.

  A preset over three flags, expanded at flag-build time (never here), so
  the seal is order-independent and an explicit `setting_sources/2` always
  wins over the scope's default:

    * `--setting-sources` (the ambient-config seal)
    * `--strict-mcp-config` (only servers from `--mcp-config`)
    * `--exclude-dynamic-system-prompt-sections` (reproducibility)

  The scope sets the seal level:

    * `:full` -> `--setting-sources ""` -- drops user + project + local
      ambient config; only claude's built-in agents remain.
    * `:project` -> `--setting-sources user` -- seals project + local
      ambient config, keeps the user's global `~/.claude`.

  Both scopes also turn off Claude Code's auto-memory by setting
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` on the spawned process. Without it,
  `--setting-sources ""` still loads `~/.claude/projects/<slug>/memory/MEMORY.md`
  into the prompt and tells the agent to write memory files there (checked
  on Claude Code 2.1.312, #327). The variable applies to `execute/2,3`,
  `stream/2` and a `DuplexSession` started with this query. A caller that
  sets the same variable in `Config.env` keeps its own value.

  With `setting_sources/2` set to `"project"` and a working directory under
  `$HOME`, Claude Code's ancestor walk also reads `~/.claude/CLAUDE.md` and
  `~/.claude/rules/` as project instructions. Hermetic never emits
  `project`.

  Hermetic seals the promptspace WITHOUT changing auth: it never emits
  `--bare` (which would force `ANTHROPIC_API_KEY` billing). OAuth /
  keychain / subscription auth is untouched.
  """
  @spec hermetic(t(), hermetic()) :: t()
  def hermetic(%__MODULE__{} = q, scope) when scope in [:full, :project],
    do: %{q | hermetic: scope}

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
  defp apply_opt({:system_prompt_file, v}, q), do: system_prompt_file(q, v)
  defp apply_opt({:append_system_prompt_file, v}, q), do: append_system_prompt_file(q, v)
  defp apply_opt({:permission_prompt_tool, v}, q), do: permission_prompt_tool(q, v)
  defp apply_opt({:max_thinking_tokens, v}, q), do: max_thinking_tokens(q, v)
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

  # Hermetic preset: `true` means the full seal; a scope atom is passed through.
  defp apply_opt({:hermetic, true}, q), do: hermetic(q, :full)

  defp apply_opt({:hermetic, scope}, q) when scope in [:full, :project],
    do: hermetic(q, scope)

  defp apply_opt({:hermetic, _}, q), do: q

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

  Automatically sets `--output-format json` for parsing. The runner is
  `ClaudeWrapper.Runner.impl/1` for `config`.

  When `ClaudeWrapper.Runner.options/1` resolves non-empty runner options for
  `config`, the call uses evidenced execution instead (stream-json output; see
  `execute/3`), because only that path can honor them. A runner without
  `c:ClaudeWrapper.Runner.run_evidenced/5` then returns
  `:evidence_unsupported` before spawning.
  """
  @spec execute(t(), Config.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def execute(%__MODULE__{} = query, %Config{} = config) do
    config = with_spawn_env(query, config)

    if Runner.options(config) == [] do
      query = %{query | output_format: :json}

      Telemetry.span_exec(query, fn -> do_execute(query, config) end)
    else
      execute_evidenced(query, config, %{session: nil, rate_limit: nil, execution: nil})
    end
  end

  @doc """
  Execute one shot while optionally observing its native session identity.

  Pass `session_observer: {local_pid, reference}` to receive exactly one
  `{reference, %ClaudeWrapper.SessionObservation{}}` after the first valid
  stdout `system/init` event. A valid ID is a nonblank string. Malformed,
  duplicate and conflicting later init events are ignored. A dead observer
  is harmless; no caller-supplied callback executes. The execution caller
  sends the observation before `execute/3` returns, preserving message order
  with any terminal reply that caller sends to the same observer.

  The observation can precede a timeout or failure and is not a completion
  signal. Callers must fence the reference against their current invocation
  before persisting it. The call still waits for transport completion and
  returns the same Result/Error categories as `execute/2`.

  Pass `rate_limit_observer: {local_pid, reference}` to receive a
  `%ClaudeWrapper.RateLimitObservation{}` for each valid stdout
  `rate_limit_event`. It can be used alone or with `:session_observer`.
  Observations are sent in stream order, before `execute/3` returns, including
  events seen before a timeout or failed transport. They are not completion
  signals. Stderr, malformed events, and other stream messages are ignored.

  Either opt-in requires a runner implementing `c:ClaudeWrapper.Runner.run_observed/5`
  (currently `ClaudeWrapper.Runner.Forcola`). Invalid observer options and
  unsupported runners return typed errors before spawning. An empty options
  list delegates to `execute/2` unchanged.

  ## Evidenced execution

  Pass `execution_observer: {local_pid, reference}` to receive exactly one
  `{reference, %ClaudeWrapper.ExecutionEvidence{}}` per call, on success or
  failure, sent by the execution caller before `execute/3` returns. Session
  observations for the same call are sent earlier, as soon as the native ID
  is seen, so to a shared observer the order is: session observation (if
  any), rate-limit observations in stream order, terminal evidence, then
  whatever the caller does with the return value. Once the options are a
  keyword list with exactly one valid `:execution_observer`, every return
  path sends the record, including rejections before spawning such as
  unknown options or other invalid observers (with `execution: :not_started`
  and no native status). An invalid or duplicated `:execution_observer`, or
  options that are not a keyword list, are rejected without a record. Runner
  raises, throws and catchable exits become
  `{:error, %Error{kind: :io, reason: {:runner_failed, kind, reason}}}` and
  still send one record. A failure converting the runner's outcome into a
  reply becomes `:io` with `{:reply_failed, kind, reason}`; its record keeps
  the native facts the runner reported. The fallback retains up to 1 MiB of observed stdout
  (lines reconstructed with newlines) and the first native session ID;
  unreported native status and cleanup stay unknown. Uncatchable process
  death cannot send a terminal record.

  Evidenced execution is selected when `:execution_observer` is given or
  when the config resolves non-empty `ClaudeWrapper.Runner.options/1`. It
  needs a runner implementing `c:ClaudeWrapper.Runner.run_evidenced/5`; any
  other runner is rejected with `:evidence_unsupported` before it is invoked,
  with no fallback. Runner options the runner cannot validate or enforce are
  rejected (`:invalid_runner_options` / `:evidence_unsupported`) before
  spawning.

  The returned Result/Error categories match observed execution, plus:
  `:timeout` for an idle bound (`:reason` is the idle milliseconds),
  `:output_limit` when an output bound cancelled the run, and `:io` with
  `{:helper_down, reason}` if the runner's collector died. Collector observer
  failures return `:io` with `{:observer_failed, kind, reason}` after the
  owned native run drains; its native terminal facts are retained. A terminal `result`
  event, a session ID, or a zero exit alone is never reported as a clean
  execution: the evidence record carries the child status, termination,
  cleanup confirmation and its scope, guard close, and retained partial
  output as separate facts. The evidence `:result` keeps a terminal result
  even when the call returns an error.
  """
  @spec execute(t(), Config.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def execute(%__MODULE__{} = query, %Config{} = config, []), do: execute(query, config)

  def execute(%__MODULE__{} = query, %Config{} = config, opts) do
    config = with_spawn_env(query, config)

    # The execution observer is extracted first so every later preflight
    # rejection (unknown or duplicate keys, other invalid observers) still
    # delivers its not-started terminal record.
    with {:ok, execution_observer} <- execution_observer(opts) do
      execute_checked(query, config, opts, execution_observer)
    end
  end

  defp execute_checked(query, config, opts, execution_observer) do
    with :ok <- validate_execution_opts(opts),
         {:ok, session_observer} <- session_observer(opts),
         {:ok, rate_limit_observer} <- rate_limit_observer(opts) do
      observers = %{
        session: session_observer,
        rate_limit: rate_limit_observer,
        execution: execution_observer
      }

      execute_with(query, config, observers)
    else
      {:error, _error} = reply -> reject_not_started(execution_observer, config, reply)
    end
  end

  defp execute_with(query, config, observers) do
    if observers.execution != nil or Runner.options(config) != [] do
      execute_evidenced(query, config, observers)
    else
      execute_observed(query, config, observers.session, observers.rate_limit)
    end
  end

  defp reject_not_started(execution_observer, config, reply) do
    send_evidence(execution_observer, Runner.not_started_evidence(), Runner.impl(config), reply)
    reply
  end

  # Only a well-formed keyword list with exactly one valid pair yields an
  # observer. Invalid or ambiguous values are rejected without a record; a
  # malformed option list has no trustworthy observer and is rejected by
  # validate_execution_opts/1.
  defp execution_observer(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      case Keyword.get_values(opts, :execution_observer) do
        [] -> {:ok, nil}
        [value] -> observer_pair(value, :execution_observer)
        _ambiguous -> {:error, observer_error(:execution_observer)}
      end
    else
      {:ok, nil}
    end
  end

  defp execute_observed(query, config, session_observer, rate_limit_observer) do
    with {:ok, runner} <- observed_runner(config) do
      query = %{query | output_format: :stream_json}

      Telemetry.span_exec(query, fn ->
        do_execute_observed(query, config, runner, session_observer, rate_limit_observer)
      end)
    end
  end

  defp session_observer(opts), do: validated_observer(opts, :session_observer)

  defp rate_limit_observer(opts), do: validated_observer(opts, :rate_limit_observer)

  @execution_keys [:session_observer, :rate_limit_observer, :execution_observer]

  defp validate_execution_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and known_unique_keys?(Keyword.keys(opts)) do
      :ok
    else
      {:error, observer_error(:session_observer)}
    end
  end

  defp validate_execution_opts(_opts), do: {:error, observer_error(:session_observer)}

  defp known_unique_keys?(keys),
    do: Enum.uniq(keys) == keys and Enum.all?(keys, &(&1 in @execution_keys))

  defp validated_observer(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, nil}
      {:ok, value} -> observer_pair(value, key)
    end
  end

  defp observer_pair({pid, reference}, _key)
       when is_pid(pid) and node(pid) == node() and is_reference(reference),
       do: {:ok, {pid, reference}}

  defp observer_pair(_value, key), do: {:error, observer_error(key)}

  defp observer_error(:session_observer), do: Error.new(:invalid_session_observer)
  defp observer_error(:rate_limit_observer), do: Error.new(:invalid_rate_limit_observer)
  defp observer_error(:execution_observer), do: Error.new(:invalid_execution_observer)

  defp observed_runner(config) do
    runner = Runner.impl(config)

    if Code.ensure_loaded?(runner) and function_exported?(runner, :run_observed, 5) do
      {:ok, runner}
    else
      {:error, Error.new(:observation_unsupported, reason: runner)}
    end
  end

  # --- Evidenced execution ---

  defp execute_evidenced(query, config, observers) do
    query = %{query | output_format: :stream_json}
    runner = Runner.impl(config)
    options = Runner.options(config)

    Telemetry.span_exec(query, fn ->
      {native, session_id, reply} = run_evidenced(query, config, runner, options, observers)
      send_evidence(observers.execution, native, runner, reply, session_id)
      reply
    end)
  end

  # Rejects a runner without the callback before invoking it; there is no
  # fallback to run/4 or run_observed/5.
  defp run_evidenced(query, config, runner, options, observers) do
    if Code.ensure_loaded?(runner) and function_exported?(runner, :run_evidenced, 5) do
      {outcome, native, session_id} = invoke_evidenced(query, config, runner, options, observers)
      {native, session_id, safe_evidenced_reply(outcome, config, runner, options)}
    else
      reason = %{runner: runner, reason: :run_evidenced_not_implemented}
      error = Error.new(:evidence_unsupported, reason: reason)
      {Runner.not_started_evidence(), nil, {:error, error}}
    end
  end

  defp invoke_evidenced(query, config, runner, options, observers) do
    base = Config.base_args(config)
    base = if "--verbose" in base, do: base, else: ["--verbose" | base]
    args = base ++ build_args(query)
    seen = make_ref()
    observe = &observe_evidenced(&1, observers.session, observers.rate_limit, seen)
    opts = Config.cmd_opts(config) ++ [runner_options: options]

    Process.put(seen, %{session_id: nil, stdout: [], size: 0, truncated: false})

    try do
      returned = runner.run_evidenced(config.binary, args, opts, config.timeout, observe)
      {outcome, native} = normalize_runner_return(returned)
      partial = Process.get(seen)
      {outcome, Map.merge(partial_evidence(partial), native), partial.session_id}
    catch
      kind, reason ->
        partial = Process.get(seen)
        native = partial_evidence(partial)
        {{:error, {:runner_failed, kind, reason}}, native, partial.session_id}
    after
      Process.delete(seen)
    end
  end

  defp normalize_runner_return({outcome, native}) when is_map(native), do: {outcome, native}

  defp normalize_runner_return(other), do: {{:error, {:invalid_runner_return, other}}, %{}}

  # Private per-invocation state survives a callback unwinding. It is bounded
  # and erased in the after clause, including on failure; no mailbox backlog.
  @failure_stdout_bytes 1_048_576

  defp retain_observed_line(seen, line) do
    partial = Process.get(seen)
    bytes = line <> "\n"
    size = min(byte_size(bytes), @failure_stdout_bytes - partial.size)
    retained = :binary.copy(binary_part(bytes, 0, size))

    Process.put(seen, %{
      partial
      | stdout: if(size > 0, do: [retained | partial.stdout], else: partial.stdout),
        size: partial.size + size,
        truncated: partial.truncated or size < byte_size(bytes)
    })
  end

  defp partial_evidence(partial) do
    %{
      execution: if(partial.size > 0, do: :started, else: :unknown),
      stdout: partial.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      output_truncated: if(partial.truncated, do: true, else: :unknown)
    }
  end

  defp observe_evidenced(line, session_observer, rate_limit_observer, seen) do
    retain_observed_line(seen, line)

    case StreamEvent.parse(line) do
      {:ok, %StreamEvent{type: "system", data: %{"subtype" => "init", "session_id" => id}}}
      when is_binary(id) ->
        announce_session(id, session_observer, rate_limit_observer, seen)

      {:ok, %StreamEvent{type: "rate_limit_event", data: data}} ->
        maybe_send_rate_limit(data, rate_limit_observer)

      _other ->
        :continue
    end
  end

  defp announce_session(id, session_observer, rate_limit_observer, seen) do
    partial = Process.get(seen)

    if String.trim(id) == "" or partial.session_id != nil do
      :continue
    else
      Process.put(seen, %{partial | session_id: id})
      maybe_send_observation(session_observer, %SessionObservation{session_id: id})
      {:continue, &observe_evidenced(&1, nil, rate_limit_observer, seen)}
    end
  end

  defp maybe_send_observation(nil, _observation), do: :ok

  defp maybe_send_observation({pid, reference}, observation),
    do: send(pid, {reference, observation})

  # Reply conversion runs after the native facts are collected, so a failure
  # here becomes a typed error and those facts still reach the terminal record.
  defp safe_evidenced_reply(outcome, config, runner, options) do
    evidenced_reply(outcome, config, runner, options)
  catch
    kind, reason -> {:error, Error.io({:reply_failed, kind, reason})}
  end

  defp evidenced_reply({:ok, {stdout, code, stderr}}, _config, _runner, _options)
       when is_binary(stdout) and is_integer(code) and code >= 0,
       do: observed_result(stdout, code, stderr)

  defp evidenced_reply({:error, :timeout}, config, _runner, _options),
    do: {:error, Error.timeout(config.timeout)}

  defp evidenced_reply({:error, :idle_timeout}, _config, _runner, options) do
    ms = options[:idle_timeout_ms]
    {:error, Error.new(:timeout, reason: ms, message: "claude produced no output for #{ms}ms")}
  end

  defp evidenced_reply({:error, {:limit, limit}}, _config, _runner, options) do
    reason = %{limit: limit, max_output_bytes: options[:max_output_bytes]}
    {:error, Error.new(:output_limit, reason: reason)}
  end

  defp evidenced_reply({:error, {:invalid_runner_options, reason}}, _config, _runner, _options),
    do: {:error, Error.new(:invalid_runner_options, reason: reason)}

  defp evidenced_reply({:error, {:evidence_unsupported, reason}}, _config, runner, _options),
    do: {:error, Error.new(:evidence_unsupported, reason: %{runner: runner, reason: reason})}

  defp evidenced_reply({:error, {:binary_not_found, _reason}}, config, _runner, _options),
    do: {:error, Error.new(:binary_not_found, reason: config.binary)}

  defp evidenced_reply({:error, reason}, _config, _runner, _options),
    do: {:error, Error.io(reason)}

  defp evidenced_reply(other, _config, _runner, _options),
    do: {:error, Error.io({:invalid_runner_return, other})}

  defp send_evidence(observer, native, runner, reply, session_id \\ nil)

  defp send_evidence(nil, _native, _runner, _reply, _session_id), do: :ok

  defp send_evidence({pid, reference}, native, runner, reply, session_id) do
    evidence =
      ExecutionEvidence.from_native(native,
        runner: runner,
        session_id: session_id,
        result: retained_result(native),
        outcome: reply
      )

    send(pid, {reference, evidence})
    :ok
  end

  defp retained_result(%{stdout: stdout}) when is_binary(stdout), do: terminal_result(stdout)
  defp retained_result(_native), do: nil

  defp do_execute_observed(query, config, runner, session_observer, rate_limit_observer) do
    base = Config.base_args(config)
    base = if "--verbose" in base, do: base, else: ["--verbose" | base]
    args = base ++ build_args(query)
    observe = &observe_events(&1, session_observer, rate_limit_observer)

    case runner.run_observed(
           config.binary,
           args,
           Config.cmd_opts(config),
           config.timeout,
           observe
         ) do
      {:ok, {stdout, code, stderr}} ->
        observed_result(stdout, code, stderr)

      {:error, :timeout} ->
        {:error, Error.timeout(config.timeout)}

      {:error, {:binary_not_found, _reason}} ->
        {:error, Error.new(:binary_not_found, reason: config.binary)}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end

  defp observe_events(line, session_observer, rate_limit_observer) do
    case StreamEvent.parse(line) do
      {:ok, %StreamEvent{type: "system", data: %{"subtype" => "init", "session_id" => id}}}
      when is_binary(id) and not is_nil(session_observer) ->
        maybe_send_session(id, session_observer, rate_limit_observer)

      {:ok, %StreamEvent{type: "rate_limit_event", data: data}} ->
        maybe_send_rate_limit(data, rate_limit_observer)

      _other ->
        :continue
    end
  end

  defp maybe_send_session(id, {pid, reference}, rate_limit_observer) do
    if String.trim(id) == "" do
      :continue
    else
      send(pid, {reference, %SessionObservation{session_id: id}})

      if is_nil(rate_limit_observer) do
        :observed
      else
        {:continue, &observe_events(&1, nil, rate_limit_observer)}
      end
    end
  end

  defp maybe_send_rate_limit(
         %{"rate_limit_info" => %{"status" => status} = info},
         {pid, reference}
       )
       when is_binary(status) and byte_size(status) > 0 do
    observation = %RateLimitObservation{
      status: status,
      rate_limit_type: optional_string(info["rateLimitType"]),
      unified_windows: optional_map(info["unifiedWindows"])
    }

    send(pid, {reference, observation})
    :continue
  end

  defp maybe_send_rate_limit(_data, _observer), do: :continue

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil

  defp optional_map(value) when is_map(value), do: value
  defp optional_map(_value), do: %{}

  defp observed_result(stdout, code, stderr) do
    case terminal_result(stdout) do
      nil when code == 0 -> {:error, Error.json(:missing_result, stdout)}
      nil -> classify_command_failure(code, stdout, stderr)
      result when code == 0 -> classify_api_error(result, code, stdout, stderr)
      result -> nonzero_result(result, code, stdout, stderr)
    end
  end

  defp terminal_result(stdout) do
    stdout
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(&result_line/1)
  end

  defp result_line(line) do
    case StreamEvent.parse(line) do
      {:ok, %StreamEvent{type: "result", data: data}} -> Result.from_json(data)
      _other -> nil
    end
  end

  defp do_execute(%__MODULE__{} = query, %Config{} = config) do
    # Strip --verbose from base args: it causes the CLI to emit non-JSON
    # output (NDJSON stream lines, stdin warnings) that breaks JSON parsing.
    # Verbose is only meaningful for stream-json output.
    base = Config.base_args(config) -- ["--verbose"]
    args = base ++ build_args(query)
    opts = Config.cmd_opts(config)

    case run_cmd(Runner.impl(config), config.binary, args, opts, config.timeout) do
      {:ok, stdout} ->
        with {:ok, result} <- parse_json_output(stdout),
             do: classify_api_error(result, 0, stdout, nil)

      {:error, %Error{kind: :command_failed, exit_code: code, stdout: stdout}} ->
        handle_nonzero_exit(code, stdout)

      {:error, _} = error ->
        error
    end
  end

  # A non-zero CLI exit that still emits valid JSON is not always a hard
  # failure: the CLI reports API errors and its rail-stop caps
  # (--max-turns and --max-budget-usd) this way, and we surface each as
  # its own typed error carrying the run's cost/turn figures; any other
  # valid-JSON result keeps its `is_error` flag and returns
  # `{:ok, %Result{}}`.
  # When the output is not decodable JSON the exit is a genuine command
  # failure -- classified as an auth error first when it looks
  # auth-shaped, otherwise plain.
  @doc false
  @spec handle_nonzero_exit(integer(), String.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def handle_nonzero_exit(code, stdout) do
    case parse_json_output(stdout) do
      {:ok, result} ->
        nonzero_result(result, code, stdout, nil)

      {:error, _} ->
        classify_command_failure(code, stdout)
    end
  end

  defp nonzero_result(result, code, stdout, stderr) do
    case rail_stop_kind(result) do
      nil ->
        classify_api_error(result, code, stdout, stderr)

      {kind, cap} ->
        reason = %{
          cap: cap,
          cost_usd: result.cost_usd,
          num_turns: result.num_turns,
          session_id: result.session_id
        }

        {:error, Error.new(kind, reason: reason, exit_code: code, stdout: stdout, stderr: stderr)}
    end
  end

  @doc false
  # A turn that ended on an API error (HTTP 429, 529, 5xx, 401, a refused
  # connection) is a result with `is_error: true` and `terminal_reason:
  # "api_error"` (Claude Code 2.1.312, #316). Return it as a typed error;
  # any other result passes through. Shared with DuplexSession.
  @spec classify_api_error(Result.t(), integer() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def classify_api_error(
        %Result{is_error: true, extra: %{"terminal_reason" => "api_error"} = extra} = result,
        code,
        stdout,
        stderr
      ) do
    status = extra["api_error_status"]

    case api_error_category(status) do
      :auth ->
        {:error,
         Error.new(:auth,
           reason: :invalid_credentials,
           exit_code: code,
           stdout: stdout,
           stderr: stderr
         )}

      category ->
        reason = %{
          status: status,
          category: category,
          api_error: extra["api_error"],
          message: result.result,
          num_turns: result.num_turns,
          session_id: result.session_id,
          cost_usd: result.cost_usd
        }

        {:error,
         Error.new(:api_error, reason: reason, exit_code: code, stdout: stdout, stderr: stderr)}
    end
  end

  def classify_api_error(%Result{} = result, _code, _stdout, _stderr), do: {:ok, result}

  defp api_error_category(429), do: :rate_limit
  defp api_error_category(529), do: :overloaded
  defp api_error_category(401), do: :auth
  defp api_error_category(nil), do: :connection
  defp api_error_category(status) when is_integer(status) and status >= 500, do: :server_error
  defp api_error_category(_status), do: :client_error

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

  defp parse_cap(_message, _type), do: nil

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
  defp classify_command_failure(code, stdout, stderr \\ nil) do
    case Auth.classify_failure(code, stdout, stderr || "") do
      nil ->
        {:error, Error.command_failed(code, stdout, stderr)}

      kind ->
        {:error, Error.new(:auth, reason: kind, exit_code: code, stdout: stdout, stderr: stderr)}
    end
  end

  @doc """
  Execute the query and return a lazy stream of `%StreamEvent{}`.

  Uses a Port with `:line` mode to read NDJSON output line-by-line.
  The port is opened when the stream is consumed and closed when
  the stream terminates.

  A clean run ends with a terminal `%StreamEvent{type: "result"}`. If the stream
  halts without one -- a timeout (`Config.timeout` bounds both the whole run
  and each gap between frames), a non-zero exit, or a spawn failure -- the
  stream ends with a terminal
  `%StreamEvent{type: "error", data: %{"error" => "stream_truncated"}}` so the
  truncation is observable. The default runner signals the CLI when the
  stream ends early (SIGINT, then SIGTERM and SIGKILL); use the
  `ClaudeWrapper.Runner.Forcola` runner to also stop its process group.

  The runner is `ClaudeWrapper.Runner.impl/1` for `config`. Streaming cannot
  honor runner options, so when `ClaudeWrapper.Runner.options/1` is non-empty
  nothing is spawned and the stream yields one terminal
  `%StreamEvent{type: "error", data: %{"error" => "runner_options_unsupported"}}`.
  """
  @spec stream(t(), Config.t()) :: Enumerable.t()
  def stream(%__MODULE__{} = query, %Config{} = config) do
    query = %{query | output_format: :stream_json}
    config = with_spawn_env(query, config)

    Telemetry.span_stream(query, fn -> do_stream(query, config) end)
  end

  @doc false
  @spec rejected_stream(String.t(), String.t()) :: [StreamEvent.t()]
  def rejected_stream(error, message) do
    [%StreamEvent{type: "error", data: %{"error" => error, "message" => message}, raw: nil}]
  end

  defp do_stream(%__MODULE__{} = query, %Config{} = config) do
    if Runner.options(config) == [] do
      do_stream_lines(query, config)
    else
      rejected_stream(
        "runner_options_unsupported",
        "runner_options are only honored by evidenced one-shot execution; nothing was spawned"
      )
    end
  end

  defp do_stream_lines(%__MODULE__{} = query, %Config{} = config) do
    # stream-json with --print requires --verbose
    base = Config.base_args(config)
    base = if "--verbose" in base, do: base, else: ["--verbose" | base]
    args = base ++ build_args(query)
    runner = Runner.impl(config)

    config.binary
    |> runner.stream_lines(args, stream_opts(config), config.timeout)
    |> Stream.transform(
      fn -> false end,
      fn line, saw_result? ->
        case StreamEvent.parse(line) do
          {:ok, %StreamEvent{type: "result"} = event} -> {[event], true}
          {:ok, event} -> {[event], saw_result?}
          {:error, _} -> {[], saw_result?}
        end
      end,
      # A clean stream-json run ends with a terminal `result` event. If the
      # stream halts without one -- a timeout, a non-zero/failed exit, or a
      # spawn failure -- the default runner ends the Stream silently, so a caller
      # cannot tell a truncated run from a clean one. Append an explicit terminal
      # `error` event so the truncation is observable (the Forcola runner already
      # raises on non-clean termination; this aligns the default path).
      fn
        true -> {[], true}
        false -> {[truncation_event()], false}
      end,
      fn _acc -> :ok end
    )
  end

  defp truncation_event do
    %StreamEvent{
      type: "error",
      data: %{
        "error" => "stream_truncated",
        "message" =>
          "the stream ended without a terminal `result` event (timeout, " <>
            "non-zero exit, or spawn failure); the run may be incomplete. The " <>
            "default runner signals only the CLI process -- use the Forcola " <>
            "runner to also stop its process group."
      },
      raw: nil
    }
  end

  defp stream_opts(%Config{working_dir: dir, env: env}) do
    [cd: dir, env: env]
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

  @doc """
  The spawn-time flag subset of a query, for a long-lived
  `ClaudeWrapper.DuplexSession`.

  Reuses `build_args/1` (the single source of flag emission, so the
  duplex and one-shot paths cannot drift), then removes the flags a
  duplex session owns itself: the transport formats
  (`--output-format` / `--input-format` / `--include-partial-messages`,
  which the session fixes to its stream-json protocol) and the leading
  `--print <prompt>` pair (in duplex the prompt is a per-turn
  stream-json message, not an argv). Everything else -- model, system
  prompt, permission mode, tool allow/deny lists, mcp config, effort,
  turn/budget caps, session continuity, and so on -- is spawn-safe and
  passes through.
  """
  @spec spawn_args(t()) :: [String.t()]
  def spawn_args(%__MODULE__{} = q) do
    %{q | output_format: nil, input_format: nil, include_partial_messages: false}
    |> build_args()
    |> drop_print_flag()
  end

  # build_args/1 emits a bare leading `--print` and the prompt last (after a
  # `--` separator). A duplex session sends prompts per-turn over stdin, so strip
  # both the leading flag and the trailing `-- <prompt>`.
  defp drop_print_flag(["--print" | rest]), do: drop_trailing_prompt(rest)
  defp drop_print_flag(args), do: drop_trailing_prompt(args)

  defp drop_trailing_prompt(args) do
    case Enum.reverse(args) do
      [_prompt, "--" | rev_rest] -> Enum.reverse(rev_rest)
      _ -> args
    end
  end

  @doc false
  @spec build_args(t()) :: [String.t()]
  def build_args(%__MODULE__{} = q) do
    q = resolve_hermetic(q)

    ["--print"]
    |> add_opt("--model", q.model)
    |> add_opt("--system-prompt", q.system_prompt)
    |> add_opt("--append-system-prompt", q.append_system_prompt)
    |> add_opt("--system-prompt-file", q.system_prompt_file)
    |> add_opt("--append-system-prompt-file", q.append_system_prompt_file)
    |> add_opt("--permission-prompt-tool", q.permission_prompt_tool)
    |> add_opt("--max-thinking-tokens", q.max_thinking_tokens && to_string(q.max_thinking_tokens))
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
    |> add_betas(q.betas)
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
    |> append_prompt(q.prompt)
  end

  # Expand the hermetic preset into its three underlying flags. Done here,
  # at flag-build time, rather than at setter time so the seal is
  # order-independent: an explicit `setting_sources` set by the caller
  # always wins over the scope's default. Auth is never touched -- hermetic
  # uses `--setting-sources`, never `--bare`.
  defp resolve_hermetic(%__MODULE__{hermetic: nil} = q), do: q

  defp resolve_hermetic(%__MODULE__{hermetic: scope} = q) do
    %{
      q
      | setting_sources: q.setting_sources || hermetic_setting_sources(scope),
        strict_mcp_config: true,
        exclude_dynamic_system_prompt_sections: true
    }
  end

  @doc false
  # The environment a query needs on top of `Config.env`, added to the
  # config at each spawn site. A caller's own entry for the same name wins.
  @spec with_spawn_env(t(), Config.t()) :: Config.t()
  def with_spawn_env(%__MODULE__{} = q, %Config{env: env} = config) do
    added = Enum.reject(spawn_env(q), fn {name, _} -> List.keymember?(env, name, 0) end)
    if added == [], do: config, else: %{config | env: env ++ added}
  end

  # Auto-memory is ambient per-project state that --setting-sources does not
  # seal (#327).
  defp spawn_env(%__MODULE__{hermetic: nil}), do: []
  defp spawn_env(%__MODULE__{}), do: [{"CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"}]

  defp hermetic_setting_sources(:full), do: ""
  defp hermetic_setting_sources(:project), do: "user"

  # The prompt is a positional argument, emitted LAST after a `--`
  # end-of-options separator so a prompt beginning with `-`/`--` (a diff line, a
  # markdown bullet, a negative number, pasted patch text) is taken literally by
  # the CLI's option parser instead of being parsed as a flag.
  defp append_prompt(args, nil), do: args
  defp append_prompt(args, prompt), do: args ++ ["--", prompt]

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

  # --betas is variadic (<betas...>): a list emits one flag followed by every
  # value; a bare string stays a single flag+value (backward compatible).
  defp add_betas(args, nil), do: args
  defp add_betas(args, betas) when is_list(betas), do: add_variadic(args, "--betas", betas)
  defp add_betas(args, beta) when is_binary(beta), do: add_opt(args, "--betas", beta)

  defp format_output_format(nil), do: nil
  defp format_output_format(:text), do: "text"
  defp format_output_format(:json), do: "json"
  defp format_output_format(:stream_json), do: "stream-json"

  defp format_output_format(other),
    do: invalid_enum!(:output_format, other, [:text, :json, :stream_json])

  # The CLI spelling of a permission mode atom; shared with
  # DuplexSession.set_permission_mode/2.
  @doc false
  @spec permission_mode_arg(permission_mode()) :: String.t()
  def permission_mode_arg(mode) when not is_nil(mode), do: format_permission_mode(mode)

  defp format_permission_mode(nil), do: nil
  defp format_permission_mode(:default), do: "default"
  defp format_permission_mode(:accept_edits), do: "acceptEdits"
  defp format_permission_mode(:bypass_permissions), do: "bypassPermissions"
  defp format_permission_mode(:dont_ask), do: "dontAsk"
  defp format_permission_mode(:plan), do: "plan"
  defp format_permission_mode(:auto), do: "auto"

  defp format_permission_mode(other),
    do:
      invalid_enum!(
        :permission_mode,
        other,
        [:default, :accept_edits, :bypass_permissions, :dont_ask, :plan, :auto]
      )

  defp format_effort(nil), do: nil
  defp format_effort(:low), do: "low"
  defp format_effort(:medium), do: "medium"
  defp format_effort(:high), do: "high"
  defp format_effort(:xhigh), do: "xhigh"
  defp format_effort(:max), do: "max"

  defp format_effort(other),
    do: invalid_enum!(:effort, other, [:low, :medium, :high, :xhigh, :max])

  defp format_input_format(nil), do: nil
  defp format_input_format(:text), do: "text"
  defp format_input_format(:stream_json), do: "stream-json"
  defp format_input_format(other), do: invalid_enum!(:input_format, other, [:text, :stream_json])

  # One actionable error for an out-of-vocabulary enum option, rather than a
  # FunctionClauseError raised deep in build_args naming only the private
  # format_* helper (#220).
  defp invalid_enum!(option, value, allowed) do
    raise ArgumentError,
          "invalid #{option} #{inspect(value)}; expected one of #{inspect(allowed)}"
  end

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

  # Execute through the configured runner and normalize to this module's
  # {:ok, stdout} | {:error, %Error{}} contract. A non-zero exit becomes
  # :command_failed (do_execute re-inspects it for a JSON rail-stop result); a
  # timeout becomes :timeout; a missing/unlaunchable binary becomes the typed
  # :binary_not_found; anything else is :io.
  defp run_cmd(runner, binary, args, opts, timeout) do
    case runner.run(binary, args, opts, timeout) do
      {:ok, {stdout, 0}} ->
        {:ok, stdout}

      {:ok, {stdout, code}} ->
        {:error, Error.command_failed(code, stdout)}

      {:error, :timeout} ->
        {:error, Error.timeout(timeout)}

      {:error, {:binary_not_found, _reason}} ->
        {:error, Error.new(:binary_not_found, reason: binary)}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end
end
