defmodule ClaudeWrapper.ChildEnv do
  @moduledoc """
  Environment adjustments for the `claude` child when the VM runs from a
  mix release (#310).

  A release start script exports `RELEASE_*` (including `RELEASE_COOKIE`),
  `erl` exports `BINDIR` and `ROOTDIR`, and the release's `erts-<vsn>/bin`
  and `bin` directories come first on `PATH`. Every command the agent runs
  inherits them: a project's own `elixir` or `mix` then resolves `erl` from
  the release and fails to boot (`cannot get bootfile`), and a project
  release the agent starts adopts the host's `RELEASE_NODE` and cookie.

  `release_scrub/1` returns the `Config.env`-style entries that undo this:
  `RELEASE_*`, `BINDIR` and `ROOTDIR` unset, and whole `PATH` entries equal
  to `BINDIR`, `ROOTDIR/bin`, `RELEASE_ROOT/bin` or
  `<ROOTDIR|RELEASE_ROOT>/erts-<vsn>/bin` removed. It returns `[]` when
  `RELEASE_ROOT` is not set. The rules follow genagent/gen_agent_server's
  `ChildEnv`.

  `ClaudeWrapper.Config` applies the scrub on every spawn path unless the
  config sets `release_env: :inherit`. Unsetting `RELEASE_COOKIE` narrows
  where the cookie is exposed; it is still readable in
  `$RELEASE_ROOT/releases/COOKIE` by the same OS user, so it is not an
  isolation boundary.
  """

  @boot_names ["BINDIR", "ROOTDIR"]

  @typedoc "A `Config.env` entry; `nil` unsets the variable."
  @type entry :: {String.t(), String.t() | nil}

  @doc """
  Entries that remove release boot variables and release `PATH` entries,
  computed from `parent` (default: this VM's environment). `[]` outside a
  release.
  """
  @spec release_scrub(%{String.t() => String.t()}) :: [entry()]
  def release_scrub(parent \\ System.get_env()) when is_map(parent) do
    if release?(parent) do
      unsets =
        parent
        |> Map.keys()
        |> Enum.filter(&boot_var?/1)
        |> Kernel.++(@boot_names)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&{&1, nil})

      unsets ++ path_entry(Map.get(parent, "PATH"), parent)
    else
      []
    end
  end

  @doc """
  The child environment for `env` (a validated `Config.env`): the release
  scrub for `parent`, then `env` on top, so a caller can still set a scrubbed
  name. A `PATH` given in `env` also has release entries removed.
  """
  @spec apply([entry()], %{String.t() => String.t()}) :: [entry()]
  def apply(env, parent \\ System.get_env()) when is_list(env) and is_map(parent) do
    case release_scrub(parent) do
      [] ->
        env

      scrub ->
        overridden = MapSet.new(env, &elem(&1, 0))

        Enum.reject(scrub, fn {name, _} -> MapSet.member?(overridden, name) end) ++
          Enum.map(env, fn
            {"PATH", path} when is_binary(path) -> {"PATH", strip_release_entries(path, parent)}
            entry -> entry
          end)
    end
  end

  @doc "True for a variable name the release scrub unsets."
  @spec boot_var?(String.t()) :: boolean()
  def boot_var?(name) when is_binary(name),
    do: name in @boot_names or String.starts_with?(name, "RELEASE_")

  defp release?(parent) do
    case Map.get(parent, "RELEASE_ROOT") do
      root when is_binary(root) and root != "" -> true
      _ -> false
    end
  end

  defp path_entry(path, parent) when is_binary(path) do
    case strip_release_entries(path, parent) do
      ^path -> []
      cleaned -> [{"PATH", cleaned}]
    end
  end

  defp path_entry(_path, _parent), do: []

  defp strip_release_entries(path, parent) do
    dirs = release_dirs(parent)
    roots = roots(parent)

    path
    |> String.split(":")
    |> Enum.reject(fn entry ->
      entry = trim_trailing_slash(entry)
      entry in dirs or Enum.any?(roots, &erts_bin?(entry, &1))
    end)
    |> Enum.join(":")
  end

  defp release_dirs(parent) do
    bindir =
      case Map.get(parent, "BINDIR") do
        dir when is_binary(dir) and dir != "" -> [trim_trailing_slash(dir)]
        _ -> []
      end

    bindir ++ Enum.map(roots(parent), &(&1 <> "/bin"))
  end

  defp roots(parent) do
    ["ROOTDIR", "RELEASE_ROOT"]
    |> Enum.map(&Map.get(parent, &1))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&trim_trailing_slash/1)
    |> Enum.uniq()
  end

  # `<root>/erts-<version>/bin` exactly, nothing deeper or beside it.
  defp erts_bin?(entry, root) do
    prefix = root <> "/erts-"

    String.starts_with?(entry, prefix) and
      match?(
        [version, "bin"] when version != "",
        String.split(String.replace_prefix(entry, prefix, ""), "/")
      )
  end

  defp trim_trailing_slash("/"), do: "/"
  defp trim_trailing_slash(entry), do: String.trim_trailing(entry, "/")
end
