defmodule ClaudeWrapper.Commands.Project do
  @moduledoc """
  Project state management commands.

  Wraps `claude project purge`, which deletes all Claude Code state for a
  project: transcripts, tasks, file history, and the project's config entry.

  > #### Destructive command {: .warning}
  >
  > `purge/2` permanently deletes project state. Pair it with `dry_run: true`
  > to preview, and `yes: true` to run headless -- the CLI hangs on its
  > confirmation prompt when stdin/stdout is not a TTY, which every wrapper
  > consumer is by definition.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Preview what would be deleted for a specific project, no confirmation
      {:ok, preview} =
        ClaudeWrapper.Commands.Project.purge(config, path: "/some/project", dry_run: true)

      # Purge a specific project headless
      {:ok, _} = ClaudeWrapper.Commands.Project.purge(config, path: "/some/project", yes: true)

      # Purge every known project headless
      {:ok, _} = ClaudeWrapper.Commands.Project.purge(config, all: true, yes: true)
  """

  alias ClaudeWrapper.{Config, Error}

  @doc """
  Delete all Claude Code state for a project.

  Removes transcripts, tasks, file history, and the project's config entry.
  Without `:path` or `:all`, the CLI defaults to the current directory.

  ## Options

    * `:path` - Purge state for the project at this path (positional argument).
      Mutually exclusive with `:all` at the CLI level.
    * `:all` - Purge state for every known project (`--all`, boolean). Mutually
      exclusive with `:path` at the CLI level.
    * `:dry_run` - List what would be deleted without deleting anything
      (`--dry-run`, boolean).
    * `:interactive` - Prompt for each item before deleting (`--interactive`,
      boolean). Only useful in TTY contexts; headless callers should leave this
      off and pair `:dry_run` with `:yes`.
    * `:yes` - Skip the confirmation prompt (`--yes`, boolean). Required when
      stdin or stdout is not a TTY, which every wrapper consumer is by
      definition.
  """
  @spec purge(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def purge(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ purge_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec purge_args(keyword()) :: [String.t()]
  def purge_args(opts) do
    flags =
      bool_flag(opts[:all], "--all") ++
        bool_flag(opts[:dry_run], "--dry-run") ++
        bool_flag(opts[:interactive], "--interactive") ++
        bool_flag(opts[:yes], "--yes")

    path = if opts[:path], do: [opts[:path]], else: []

    ["project", "purge"] ++ flags ++ path
  end

  defp bool_flag(true, flag), do: [flag]
  defp bool_flag(_falsy, _flag), do: []
end
