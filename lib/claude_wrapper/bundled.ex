defmodule ClaudeWrapper.Bundled do
  # The claude CLI version this release pins the bundled binary to. Bump
  # in lockstep with upstream CLI releases we have validated against.
  @pinned_version "2.0.0"

  @moduledoc """
  Opt-in bundled-binary resolution for the `claude` CLI.

  By default `claude_wrapper` expects `claude` on `PATH` (see
  `ClaudeWrapper.Config.find_binary/0`). This module is the alternative:
  resolve, install, and version-pin a `claude` binary under the package's
  `priv/bin/`, so an app can depend on `claude_wrapper` and get a known
  CLI without a separate install step on PATH.

  It is **opt-in** -- nothing here runs unless you ask for it, via
  `ClaudeWrapper.Config.new(binary: :bundled)`, the `mix claude_wrapper.*`
  tasks, or calling `ensure!/0` directly. The stdlib-minimal default and
  its dependency footprint are unchanged for everyone else.

  ## Resolution vs install

  `path/0` is pure: it returns where the bundled binary lives, whether or
  not it is present. `Config.new(binary: :bundled)` resolves to that path
  and does **not** touch the network -- a struct constructor should not
  download anything. Installing is an explicit step:

      mix claude_wrapper.install      # or: ClaudeWrapper.Bundled.ensure!()

  `ensure/0` installs only when the binary is missing or its version does
  not match `pinned_version/0`.

  ## Version pin

  The pinned version is `#{@pinned_version}`.
  `install/0` verifies the freshly-installed binary reports that version;
  it does not attempt to coerce an arbitrary version out of the upstream
  installer.
  """

  alias ClaudeWrapper.{CliVersion, Error}

  # Anthropic's official installer (POSIX shell). Piped to `sh` with a
  # temp HOME so it does not touch the user's real install.
  @install_script_url "https://claude.ai/install.sh"

  @doc "The pinned CLI version the bundled binary is expected to be."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @pinned_version

  @doc """
  Absolute path to the bundled binary, `priv/bin/claude`.

  Pure -- returns the path whether or not the binary is installed.
  """
  @spec path() :: String.t()
  def path do
    :claude_wrapper
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("bin")
    |> Path.join("claude")
  end

  @doc "Whether the bundled binary is present on disk."
  @spec installed?() :: boolean()
  def installed?, do: File.exists?(path())

  @doc """
  The version the installed bundled binary reports, or `nil` if it is not
  installed (or `--version` could not be parsed).
  """
  @spec installed_version() :: CliVersion.t() | nil
  def installed_version do
    bin = path()

    with true <- File.exists?(bin),
         {out, 0} <- System.cmd(bin, ["--version"], stderr_to_stdout: true),
         {:ok, version} <- CliVersion.parse(out) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  Ensure a bundled binary matching `pinned_version/0` is installed.

  Installs when the binary is missing or reports a different version;
  otherwise a no-op. Returns `{:ok, path}` or `{:error, %Error{}}`.
  """
  @spec ensure() :: {:ok, String.t()} | {:error, Error.t()}
  def ensure do
    if up_to_date?() do
      {:ok, path()}
    else
      install()
    end
  end

  @doc "Like `ensure/0` but returns the path or raises on failure."
  @spec ensure!() :: String.t()
  def ensure! do
    case ensure() do
      {:ok, bin} -> bin
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Download and install the pinned `claude` binary into `priv/bin/`.

  Runs Anthropic's official installer in a temporary `HOME`, copies the
  resulting binary into place, marks it executable, and (on macOS) retries
  once after clearing the Gatekeeper quarantine if the first run is killed
  (exit 137). Returns `{:ok, path}` or `{:error, %Error{}}`.
  """
  @spec install() :: {:ok, String.t()} | {:error, Error.t()}
  def install do
    dest = path()
    File.mkdir_p!(Path.dirname(dest))

    with {:ok, tmp_home} <- make_temp_home(),
         {:ok, installed} <- run_installer(tmp_home),
         :ok <- copy_binary(installed, dest),
         :ok <- verify_version(dest) do
      _ = File.rm_rf(tmp_home)
      {:ok, dest}
    end
  end

  @doc "Remove the bundled binary. Idempotent."
  @spec uninstall() :: :ok
  def uninstall do
    _ = File.rm_rf(path())
    :ok
  end

  # -- internals -----------------------------------------------------

  defp up_to_date? do
    case {installed?(), installed_version()} do
      {true, %CliVersion{} = v} -> CliVersion.to_string(v) == @pinned_version
      _ -> false
    end
  end

  defp make_temp_home do
    base =
      Path.join(System.tmp_dir!(), "claude_wrapper_install_#{System.unique_integer([:positive])}")

    case File.mkdir_p(base) do
      :ok -> {:ok, base}
      {:error, reason} -> {:error, Error.new(:io, reason: reason)}
    end
  end

  defp run_installer(tmp_home) do
    env = [{"HOME", tmp_home}]
    cmd = "curl -fsSL #{@install_script_url} | sh"

    case System.cmd("sh", ["-c", cmd], env: env, stderr_to_stdout: true) do
      {_out, 0} ->
        locate_installed(tmp_home)

      {out, code} ->
        {:error,
         Error.new(:command_failed,
           reason: "bundled install failed",
           exit_code: code,
           stderr: out
         )}
    end
  end

  # The installer drops the binary somewhere under the temp HOME; find it.
  defp locate_installed(tmp_home) do
    tmp_home
    |> Path.join("**/claude")
    |> Path.wildcard()
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> {:error, Error.new(:not_found, reason: :installed_binary)}
      found -> {:ok, found}
    end
  end

  defp copy_binary(src, dest) do
    with {:ok, _} <- File.copy(src, dest),
         :ok <- File.chmod(dest, 0o755) do
      :ok
    else
      {:error, reason} -> {:error, Error.new(:io, reason: reason)}
    end
  end

  # Confirm the installed binary reports the pinned version. On macOS the
  # first exec of a freshly-copied binary can be SIGKILLed by Gatekeeper
  # (exit 137); clear the quarantine xattr and retry once.
  defp verify_version(dest) do
    case System.cmd(dest, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        check_pinned(out, dest)

      {_out, 137} ->
        retry_after_gatekeeper(dest)

      {out, code} ->
        {:error,
         Error.new(:command_failed,
           reason: "bundled --version failed",
           exit_code: code,
           stderr: out
         )}
    end
  end

  defp retry_after_gatekeeper(dest) do
    _ = System.cmd("xattr", ["-d", "com.apple.quarantine", dest], stderr_to_stdout: true)

    case System.cmd(dest, ["--version"], stderr_to_stdout: true) do
      {out, 0} ->
        check_pinned(out, dest)

      {out, code} ->
        {:error,
         Error.new(:command_failed,
           reason: "bundled --version failed after Gatekeeper retry",
           exit_code: code,
           stderr: out
         )}
    end
  end

  defp check_pinned(version_output, _dest) do
    case CliVersion.parse(version_output) do
      {:ok, v} ->
        if CliVersion.to_string(v) == @pinned_version do
          :ok
        else
          {:error,
           Error.new(:version_mismatch,
             reason: {:expected, @pinned_version, :got, CliVersion.to_string(v)}
           )}
        end

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end
end
