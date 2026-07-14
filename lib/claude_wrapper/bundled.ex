defmodule ClaudeWrapper.Bundled do
  # The MINIMUM claude CLI version the bundled binary must satisfy -- a floor,
  # not an exact pin. The upstream installer always fetches the current stable
  # CLI (it takes no version argument), so an exact-match assertion failed on
  # every healthy machine once the installer moved past this value; a floor
  # accepts the installed CLI as long as it is at least this validated version.
  @minimum_version "2.0.0"

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

  `ensure/0` installs only when the binary is missing or its version is
  below `minimum_version/0`.

  ## Minimum version

  The bundled binary must be at least `#{@minimum_version}`.
  `install/0` fetches the current stable CLI and verifies it reports a
  version `>=` this floor; it does not coerce an exact version out of the
  upstream installer (which takes no version argument).
  """

  alias ClaudeWrapper.{CliVersion, Error}

  # Anthropic's official installer (POSIX shell). Downloaded to a temp file
  # and run with a temp HOME so it does not touch the user's real install.
  @install_script_url "https://claude.ai/install.sh"

  @doc "The minimum CLI version the bundled binary must satisfy (a floor)."
  @spec minimum_version() :: String.t()
  def minimum_version, do: @minimum_version

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
  Ensure a bundled binary satisfying `minimum_version/0` is installed.

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
      {true, %CliVersion{} = v} -> meets_minimum?(v)
      _ -> false
    end
  end

  # The installed CLI satisfies the floor (installed >= @minimum_version).
  defp meets_minimum?(%CliVersion{} = installed) do
    case CliVersion.parse(@minimum_version) do
      {:ok, minimum} -> CliVersion.check_version(installed, minimum) == :ok
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
    script = Path.join(tmp_home, "install.sh")

    # Download to a file FIRST, then run it -- do not `curl ... | sh`. A POSIX
    # pipeline exits with `sh`'s status, so a curl-side failure (404 under -f,
    # DNS/TLS error, mid-stream reset, curl missing) would exit 0 with sh having
    # run on empty/partial stdin: fail-open, with curl's stderr discarded.
    # Checking curl's own exit code makes a download failure a real error.
    with {_out, 0} <-
           System.cmd("curl", ["-fsSL", "-o", script, @install_script_url],
             env: env,
             stderr_to_stdout: true
           ),
         {_out, 0} <- System.cmd("sh", [script], env: env, stderr_to_stdout: true) do
      locate_installed(tmp_home)
    else
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
        if meets_minimum?(v) do
          :ok
        else
          {:error,
           Error.new(:version_mismatch,
             reason: {:minimum, @minimum_version, :got, CliVersion.to_string(v)}
           )}
        end

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end
end
