defmodule Mix.Tasks.Claude.Contract do
  @shortdoc "Check emitted argv against an explicitly selected Claude CLI"
  @moduledoc """
  Check flags emitted by query, resident spawn and command builders against
  native CLI help, without authentication or inference.

      CLAUDE_CONTRACT_BIN=/path/to/claude mix claude.contract

  `CLAUDE_CONTRACT_VERSION` optionally requires an exact reported version.
  This checks emitted flags, not the semantics of values or coverage of every
  new upstream option. Commands are rendered with a task-local fake executable; the real
  binary is invoked only with `--version` and `--help`.
  """

  use Mix.Task

  alias ClaudeWrapper.{Config, Query}

  alias ClaudeWrapper.Commands.{
    Agents,
    Auth,
    AutoMode,
    Doctor,
    Install,
    Marketplace,
    Mcp,
    Plugin,
    Project,
    Ultrareview,
    Update,
    Version
  }

  @requirements ["app.start"]

  # These required-value flags are hidden on 2.1.309. A missing-operand
  # parse error proves recognition on each run, rather than waiving drift.
  @hidden_value_flags ~w(--max-turns --system-prompt-file --append-system-prompt-file --permission-prompt-tool --max-thinking-tokens)

  @impl true
  def run(_argv) do
    binary =
      System.get_env("CLAUDE_CONTRACT_BIN") || System.find_executable("claude") ||
        Mix.raise("set CLAUDE_CONTRACT_BIN or put claude on PATH")

    {version, 0} = System.cmd(binary, ["--version"], stderr_to_stdout: true)
    verify_version!(String.trim(version), System.get_env("CLAUDE_CONTRACT_VERSION"))
    Mix.shell().info(String.trim(version))
    findings = check(binary)

    if findings == [] do
      Mix.shell().info(
        "No drift: emitted flags are listed or pass explicit hidden-option probes."
      )
    else
      Enum.each(findings, fn finding -> Mix.shell().error(finding) end)
      Mix.raise("Claude CLI contract drift")
    end
  end

  @doc false
  @spec check(String.t(), [{[String.t()], [String.t()]}]) :: [String.t()]
  def check(binary, commands \\ specs()) do
    Enum.flat_map(commands, fn {subcommand, args} -> check_command(binary, subcommand, args) end)
  end

  defp verify_version!(_reported, nil), do: :ok

  defp verify_version!(reported, expected) do
    unless Regex.run(~r/\b\d+\.\d+\.\d+\b/, reported) == [expected],
      do: Mix.raise("expected claude #{expected}, got: #{reported}")
  end

  defp check_command(binary, subcommand, args) do
    {help, code} = System.cmd(binary, subcommand ++ ["--help"], stderr_to_stdout: true)

    expected =
      "Usage: claude" <> if(subcommand == [], do: " ", else: " " <> Enum.join(subcommand, " "))

    documented = help_flags(help)

    if code != 0 or not String.contains?(help, expected) or MapSet.size(documented) == 0 do
      ["#{Enum.join(subcommand, " ")}: no usable command help; contract would be blind"]
    else
      args
      |> emitted_flags()
      |> Enum.reject(&listed?(binary, &1, documented, subcommand))
      |> Enum.map(&"#{Enum.join(subcommand, " ")}: emitted #{&1} is not documented")
    end
  end

  defp listed?(binary, flag, documented, subcommand) do
    cond do
      MapSet.member?(documented, flag) -> true
      subcommand == [] and flag in @hidden_value_flags -> recognized_hidden?(binary, flag)
      true -> false
    end
  end

  defp recognized_hidden?(binary, flag) do
    {output, code} = System.cmd(binary, ["-p", flag], stderr_to_stdout: true)

    code != 0 and String.contains?(output, "option '#{flag} ") and
      String.contains?(output, "argument missing")
  end

  defp emitted_flags(args) do
    args
    |> Enum.take_while(&(&1 != "--"))
    |> Enum.filter(&String.starts_with?(&1, "-"))
    |> Enum.uniq()
  end

  defp help_flags(help) do
    help
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "  -"))
    |> Enum.flat_map(fn line ->
      head = line |> String.trim() |> String.split(~r/\s{2,}|\s+[<\[]/, parts: 2) |> hd()

      Regex.scan(~r/(?:^|, )(-{1,2}[a-zA-Z][a-zA-Z0-9-]*)/, head, capture: :all_but_first)
      |> List.flatten()
    end)
    |> MapSet.new()
  end

  defp capture(fun) do
    dir = Path.join(System.tmp_dir!(), "claude-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    binary = Path.join(dir, "capture")
    args_path = Path.join(dir, "args")

    File.write!(binary, """
    #!/bin/sh
    printf '%s\\000' "$@" > #{ClaudeWrapper.Command.shell_escape(args_path)}
    printf '{}'
    """)

    File.chmod!(binary, 0o755)

    config =
      Config.new(
        binary: binary,
        timeout: 5_000,
        runner: ClaudeWrapper.Runner.Port,
        runner_options: [],
        env: [{"CLAUDE_CONTRACT_CAPTURE", args_path}]
      )

    try do
      fun.(config)
      args_path |> File.read!() |> String.split(<<0>>) |> Enum.drop(-1)
    after
      File.rm_rf!(dir)
    end
  end

  defp maximal_query do
    Query.new("contract prompt")
    |> Query.apply_opts(
      model: "sonnet",
      system_prompt: "contract",
      append_system_prompt: "contract",
      system_prompt_file: "/tmp/system",
      append_system_prompt_file: "/tmp/append",
      permission_prompt_tool: "stdio",
      max_thinking_tokens: 10,
      output_format: :json,
      max_budget_usd: 1.0,
      permission_mode: :default,
      effort: :low,
      max_turns: 2,
      json_schema: "{}",
      resume: "contract-id",
      session_id: "contract-id",
      fallback_model: "haiku",
      from_pr: "1",
      agent: "contract",
      agents_json: "{}",
      input_format: :stream_json,
      settings: "{}",
      debug_filter: "api",
      debug_file: "/tmp/debug",
      betas: ["contract"],
      name: "contract",
      setting_sources: "",
      allowed_tools: ["Read"],
      disallowed_tools: ["Bash"],
      mcp_config: ["/tmp/mcp.json"],
      add_dir: ["/tmp"],
      tools: ["Read"],
      files: ["id:path"],
      plugin_dirs: ["/tmp/plugin"],
      plugin_urls: ["https://example.invalid/plugin"],
      safe_mode: true,
      continue_session: true,
      no_session_persistence: true,
      dangerously_skip_permissions: true,
      include_partial_messages: true,
      strict_mcp_config: true,
      fork_session: true,
      worktree: true,
      brief: true,
      tmux: true,
      prompt_suggestions: true,
      replay_user_messages: true,
      bare: true,
      disable_slash_commands: true,
      include_hook_events: true,
      exclude_dynamic_system_prompt_sections: true
    )
  end

  defp specs do
    query = maximal_query()
    query_args = Query.build_args(query)

    spawn_args =
      Query.spawn_args(query) ++
        ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]

    [{[], query_args}, {[], spawn_args}] ++ command_specs()
  end

  defp command_specs do
    [
      {["auth", "status"], &Auth.status/1},
      {["auth", "login"],
       &Auth.login(&1,
         email: "contract@example.invalid",
         mode: :console,
         force_sso: true
       )},
      {["auth", "login"], &Auth.login(&1, mode: :claudeai)},
      {["auth", "logout"], &Auth.logout/1},
      {["agents"], &Agents.list(&1, all: true, setting_sources: "")},
      {["auto-mode", "config"], &AutoMode.config/1},
      {["auto-mode", "defaults"], &AutoMode.defaults/1},
      {["auto-mode", "critique"], &AutoMode.critique(&1, model: "sonnet")},
      {["mcp", "list"], &Mcp.list/1},
      {["mcp", "get"], &Mcp.get(&1, "contract")},
      {["mcp", "add"],
       &Mcp.add(&1, "contract", "https://example.invalid/mcp", [],
         scope: :user,
         transport: :http,
         header: ["X-Test: value"],
         env: %{"TEST" => "value"},
         callback_port: 8080,
         client_id: "contract",
         client_secret: true,
         server_args: ["--synthetic"]
       )},
      {["mcp", "add-json"],
       &Mcp.add_json(&1, "contract", "{}", scope: :user, client_secret: true)},
      {["mcp", "add-from-claude-desktop"], &Mcp.add_from_desktop(&1, scope: :user)},
      {["mcp", "remove"], &Mcp.remove(&1, "contract", scope: :user)},
      {["mcp", "serve"], &Mcp.serve(&1, debug: true, verbose: true)},
      {["plugin", "list"], &Plugin.list(&1, available: true)},
      {["plugin", "install"],
       &Plugin.install(&1, "contract", scope: :user, config: ["key=value"])},
      {["plugin", "uninstall"],
       &Plugin.uninstall(&1, "contract", scope: :user, keep_data: true, prune: true, yes: true)},
      {["plugin", "enable"], &Plugin.enable(&1, "contract", scope: :user)},
      {["plugin", "disable"], &Plugin.disable(&1, "contract", scope: :user, all: true)},
      {["plugin", "update"], &Plugin.update(&1, "contract", scope: :user)},
      {["plugin", "validate"], &Plugin.validate(&1, "/tmp/plugin", strict: true)},
      {["plugin", "tag"],
       &Plugin.tag(&1,
         message: "contract",
         push: true,
         dry_run: true,
         force: true,
         remote: "origin",
         path: "/tmp/plugin"
       )},
      {["plugin", "details"], &Plugin.details(&1, "contract")},
      {["plugin", "prune"], &Plugin.prune(&1, yes: true, dry_run: true, scope: :user)},
      {["plugin", "marketplace", "list"], &Marketplace.list/1},
      {["plugin", "marketplace", "add"],
       &Marketplace.add(&1, "contract", scope: :user, sparse: ["plugins"])},
      {["plugin", "marketplace", "remove"], &Marketplace.remove(&1, "contract", scope: :user)},
      {["plugin", "marketplace", "update"], &Marketplace.update(&1, "contract")},
      {["install"], &Install.install(&1, force: true, target: "stable")},
      {["doctor"], &Doctor.execute/1},
      {[], &Version.execute/1},
      {["update"], &Update.update/1},
      {["project", "purge"],
       &Project.purge(&1,
         dry_run: true,
         yes: true,
         all: true,
         interactive: true,
         path: "/tmp/project"
       )},
      {["ultrareview"], &Ultrareview.execute(&1, json: true, timeout: 60, target: "contract")}
    ]
    |> Enum.map(fn {subcommand, fun} -> {subcommand, capture(fun)} end)
  end
end
